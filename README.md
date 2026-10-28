# Kubernetes on OCI: OKE with NGINX Ingress, OCIR and NoSQL

The Oracle Cloud member of the **Kubernetes in the Cloud** series, a port of
[aws-k8s](https://github.com/mamonaco1973/aws-k8s). The candidate
microservice runs on **Oracle Container Engine for Kubernetes (OKE)**, next
to three browser games (Tetris, Frogger and Breakout). Images live in
**OCIR**, the Flask pods store candidates in **OCI NoSQL** through OKE
workload identity, and an **NGINX ingress controller** behind one OCI load
balancer routes to everything. Terraform builds the infrastructure and the
add-ons; `kubectl` deploys the apps.

| Piece | Where | Role |
|---|---|---|
| **k8s-vcn** | `10.0.0.0/24`, your CLI's region | three regional subnets: API endpoint `10.0.0.0/28`, load balancers `10.0.0.16/28`, worker nodes `10.0.0.128/25`; internet, NAT and service gateways |
| **flask-oke-cluster** | OKE, `ENHANCED_CLUSTER` | managed control plane with a public API endpoint (6443 open); Flannel overlay; the in-cluster cloud controller creates load balancers |
| **flask-nodes** | node pool | `VM.Standard.E5.Flex`, 2 OCPUs and 16 GB; 1 to 4 nodes, scaled by the cluster autoscaler; runs `flask-app` and the ingress controller |
| **game-nodes** | node pool | same shape, 1 node; runs the games in the `games` namespace |
| **Add-ons** | Helm, `kube-system` / `ingress-nginx` | metrics-server, cluster autoscaler (registered for `flask-nodes` only) and the NGINX ingress controller |
| **OCI load balancer** | load balancer subnet | flexible, 10 to 100 Mbps, for the NGINX service; port 80 open to the internet |
| **flask-app** | Deployment | 2 replicas, scaled 2 to 5 by an HPA at 60% CPU; `/gtg` probes; service account `nosql-access-sa` |
| **tetris**, **frogger**, **breakout** | Deployments, `games` | one replica each |
| **Candidates** | OCI NoSQL | 50 read and 50 write units |
| **flask-app**, **games** | OCIR | the images, pulled with the `ocir-secret` image pull secret |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="Requests from the internet reach a flexible OCI load balancer in the load balancer subnet, created by the cloud controller in the flask-oke-cluster enhanced OKE cluster for the NGINX ingress controller's service. The ingress routes /flask-app/api to the Flask pods on the flask-nodes pool (VM.Standard.E5.Flex with 2 OCPUs and 16 GB, one to four nodes, scaled by the cluster autoscaler) and /games paths to the Tetris, Frogger and Breakout pods on the single-node game-nodes pool. The Flask pods read and write the Candidates NoSQL table through OKE workload identity as the nosql-access-sa service account. Both pools pull images from OCIR with an image pull secret." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`01-ocir/`**: the VCN, subnets, gateways and security lists, and the
  two OCIR repositories.
- **`02-docker/`**: the Flask app and the three games, each with its
  `Dockerfile`, plus the `test_candidates.py` smoke test.
- **`03-oke/`**: the cluster and both pools, the NoSQL table, the IAM
  policies (workload identity, autoscaler), the Helm releases, and the
  manifest templates in `yaml/`.
- **`oci-env.sh`**: derives the tenancy, user, region and OCIR settings from
  `~/.oci/config`; sourced by the scripts.
- **`stress.yaml`**: a CPU load generator for the autoscaling test.

## What changed from the AWS build

The Kubernetes side is almost untouched — the same Deployments, Services, Ingresses and HPA. Nearly all of the difference is in what sits underneath.

| Concern | AWS | OCI |
|---|---|---|
| Registry | ECR, addressed by account ID | OCIR, addressed by object storage namespace |
| Cluster | EKS | OKE, `ENHANCED_CLUSTER` |
| Database | DynamoDB | OCI NoSQL Database |
| Pod → database auth | IRSA (OIDC provider + IAM role) | OKE workload identity |
| Load balancer | AWS Load Balancer Controller (Helm chart + IAM policy) | Built into OKE — nothing to install |
| Image pull | Node instance role, no secret needed | `imagePullSecrets` required |
| Subnets | 2 public + 2 private, one pair per AZ | 3 regional subnets, split by role |
| Node autoscaling target | Discovered from EC2 tags | Node pool OCID, named explicitly |

Four of these are worth expanding on.

### The load balancer controller is gone

The AWS build installed the **AWS Load Balancer Controller** so Kubernetes could create an ALB at all: a Helm chart, a service account, an IRSA role, and a roughly two-hundred-line IAM policy enumerating every `elasticloadbalancing:*` and `ec2:*` action it might need.

OKE ships the **OCI cloud controller manager** inside the cluster. A `Service` of type `LoadBalancer` provisions an OCI Load Balancer with no controller to install and no policy to write. The entire `alb.tf` file and its template were deleted with nothing put in their place.

### IRSA became workload identity

IRSA on EKS required an OIDC identity provider resource, a TLS certificate data source to scrape the issuer's thumbprint, an assumable-role module, an IAM role, a policy, and a service account annotated with the role ARN.

The OCI equivalent is one policy statement:

```
Allow any-user to manage nosql-rows in compartment id <ocid> where all {
  request.principal.type = 'workload',
  request.principal.namespace = 'default',
  request.principal.service_account = 'nosql-access-sa',
  request.principal.cluster_id = '<cluster ocid>'
}
```

The service account itself needs no annotation. In the pod, `get_oke_workload_identity_resource_principal_signer()` replaces the ambient IAM credential boto3 was picking up.

This is why the cluster is created as an `ENHANCED_CLUSTER` — a basic cluster cannot issue workload principal tokens at all.

### Four subnets became three

AWS subnets are **zonal**, so the original build ran two public and two private subnets — one pair per availability zone — because an ALB needs a subnet in at least two zones.

OCI subnets are **regional**. A single subnet already spans every availability domain, and the load balancer distributes itself. The AZ pairing has nothing to do, so the four subnets collapse to three split by role instead: the Kubernetes API endpoint, the load balancers, and the worker nodes.

### The autoscaler has to be told what to scale

The AWS cluster autoscaler discovered its scaling targets by reading EC2 tags, so tagging a node group was enough to enrol it. The OCI provider has no tag discovery: each node pool is passed explicitly as `min:max:ocid`, and a pool that is not listed is invisible to it.

Only the flask pool is registered, on purpose. The game pool never scales.

## Endpoints

| Path | Returns |
|---|---|
| `GET /flask-app/api/gtg` | 200; with `?details=true`, `{"connected": "true", "hostname": <pod IP>}` |
| `GET /flask-app/api/candidate/<name>` | the candidate, or 404 |
| `POST /flask-app/api/candidate/<name>` | `{"CandidateName": <name>}`, or 500 |
| `GET /flask-app/api/candidates` | every candidate, or 404 |
| `GET /games/tetris` | Tetris |
| `GET /games/frogger` | Frogger |
| `GET /games/breakout` | Breakout |

The games are [Tetris](https://gist.github.com/straker/3c98304f8a6a9174efd8292800891ea1),
[Frogger](https://gist.github.com/straker/82a4368849cbd441b05bd6a044f2b2d3)
and [Breakout](https://gist.github.com/straker/98a2aed6a7686d26c04810f08bfaf66b)
by Steven Lambert, served by NGINX.

| Tetris | Frogger | Breakout |
|---|---|---|
| ![Tetris](diagrams/tetris.png) | ![Frogger](diagrams/frogger.png) | ![Breakout](diagrams/breakout.png) |

## Prerequisites

* [An OCI Account](https://cloud.oracle.com/)
* [Install OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm)
  and run `oci setup config`
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install Docker](https://docs.docker.com/engine/install/)
* [Install kubectl](https://kubernetes.io/docs/tasks/tools/) and
  [jq](https://jqlang.github.io/jq/download/)

The OCI CLI is required, not just convenient: Terraform's `kubernetes` and
`helm` providers get their token by running `oci ce cluster
generate-token`. Two optional overrides: `OCI_COMPARTMENT_ID` (default: the
tenancy root) and `OCI_REGION` (default: the region in `~/.oci/config`).

## Deploy

```bash
git clone https://github.com/mamonaco1973/oci-k8s.git
cd oci-k8s
./apply.sh
```

On the first run `apply.sh` creates an OCIR auth token and caches it in
`~/.oci/ocir_token`. A token can only be read when it's created, so delete
the file to force a new one; OCI allows two per user, so you may need to
remove an old one in the console first. Then:

1. Applies **`01-ocir`** (network and repositories).
2. Builds and pushes the Flask image and the three game images to OCIR.
3. Applies **`03-oke`**: the cluster, both pools, the table, the policies,
   the add-ons and the `ocir-secret` pull secret in both namespaces. This
   takes about 15 minutes.
4. Configures `kubectl` with `oci ce cluster create-kubeconfig` and applies
   `flask-app.yaml` and `games.yaml`.

It ends by running `validate.sh`, which waits for the ingress IP and the
health check, runs the smoke test, and prints the URLs:

```
✓ good to go passed
✓ insert passed
✓ verification passed
✓ candidate list passed

NOTE: Flask API   - http://<lb IP>/flask-app/api/gtg?details=true
NOTE: Tetris      - http://<lb IP>/games/tetris/
NOTE: Breakout    - http://<lb IP>/games/breakout/
NOTE: Frogger     - http://<lb IP>/games/frogger/
```

## Try it

1. Open the game URLs in a browser and call the Flask API with `curl` or
   Postman.
2. Check the workloads; the ingress `ADDRESS` is an IP, because an OCI load
   balancer has no DNS name of its own:

   ```bash
   kubectl get pods,deployments,ingress
   kubectl get pods,deployments,ingress -n games
   kubectl get nodes
   ```

3. Test autoscaling with the load generator in `stress.yaml`:

   ```bash
   kubectl apply -f stress.yaml
   # wait about 5 minutes
   kubectl get nodes          # flask-nodes grows, up to 4 nodes
   kubectl delete -f stress.yaml
   # wait about 5 minutes
   kubectl get nodes          # and shrinks back
   ```

## Teardown

```bash
./destroy.sh
```

The order matters. The OCI Load Balancer is created by the in-cluster cloud controller manager, not by Terraform, so Terraform does not know it exists. `destroy.sh` removes the ingress release first so the controller can delete its own load balancer while it is still running — otherwise the balancer is stranded and blocks the subnet, and therefore the VCN, from being deleted.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Flask pod gets a 404 from NoSQL on every call | Workload identity is not matching. Check that the pod's service account, its namespace and the cluster OCID all match the policy in [03-oke/iam.tf](./03-oke/iam.tf). A mismatch resolves to no groups and reads as 404, not 403 |
| Flask pod CrashLoopBackOff, "Must supply either a region or an endpoint" | The OKE workload identity signer carries no region, unlike a resource principal signer. `NosqlClient` needs `config={"region": ...}` — supplied from the `OCI_REGION` env var in the deployment |
| Rebuilt image but the pods behave the same | The image tags are mutable, so `imagePullPolicy: Always` is required. Restart the deployment to force a pull: `kubectl rollout restart deployment/flask-app` |
| Pods stuck in `ImagePullBackOff` | The `ocir-secret` is missing from that namespace, or the cached auth token in `~/.oci/ocir_token` was revoked |
| Pods stuck in `Pending` | No node carries the `nodegroup` label the deployment selects on. Check `kubectl get nodes --show-labels` |
| Ingress `ADDRESS` stays empty | The load balancer is still provisioning, or the `lb` subnet was not passed as `service_lb_subnet_ids` on the cluster |
| HPA reports `<unknown>` for CPU | metrics-server is not running or is failing TLS verification against the kubelets — see the `--kubelet-insecure-tls` argument in [03-oke/helm.tf](./03-oke/helm.tf) |
| Autoscaler never adds nodes | The node pool OCID is not in the autoscaler values, or the worker node dynamic group did not exist when the nodes booted. An instance principal caches its group membership at boot — the nodes must be recycled after a group change |
| `terraform destroy` fails on the subnet | A load balancer still exists. Delete the ingress controller's Service and wait for the balancer to disappear before retrying |
| `oci ce cluster generate-token` not found | The OCI CLI is missing from PATH where Terraform runs |
| NoSQL: "Free tables are not available at this region" | `is_auto_reclaimable = true` requests the always-free tier, which not every region offers. It is `false` in [03-oke/nosql.tf](./03-oke/nosql.tf) |
| Node pool 409: "Kubernetes version does not match ... worker node image" | The image match found a version whose number merely starts with yours — 1.33.1 matching 1.33.10. The pattern in [03-oke/oke.tf](./03-oke/oke.tf) is anchored with a trailing hyphen |
| Node pool 400: "Node shape and image are not compatible" | An aarch64 image was selected for an x86 shape. The node pool options data source returns both architectures; the filter in [03-oke/oke.tf](./03-oke/oke.tf) derives the right one from `var.node_shape` |
| `destroy.sh` fails with "No value for required variable" | You are on an older copy. Both scripts now source [oci-env.sh](./oci-env.sh) — Terraform needs the same variables on destroy as on apply |

## Notes

- **Lab only.** The API and games are open to the internet over plain HTTP,
  and the Kubernetes API endpoint accepts 6443 from anywhere.
- `diagrams/consoles.gif` is the AWS console tour from aws-k8s, so it isn't
  shown here.
