#!/usr/bin/env python3
"""Generate the oci-k8s architecture diagrams in the lucid style.

Emits two draw.io files matching the house style established by
oci-resume-app/gen_diagram.py: 1920x1080 canvas, dashed navy region frame,
rounded white cards with a colored 2px stroke, a 52px lucide icon, a 22px
bold title and 15px grey subtitles, and 2.5px orthogonal edges with bold
16px labels.

  oci-k8s.drawio        the traffic path — one load balancer, one ingress,
                        two node pools, and where the data lives
  oci-k8s-infra.drawio  the network — one VCN, three REGIONAL subnets, and a
                        control plane Oracle runs rather than you

Both are laid out so the thing that differs from the AWS original is visible
in the shape: there is no load balancer controller to draw, and the subnets
are split by role rather than paired across availability zones.
"""

import os
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))

# ==============================================================================
# Palette — one hue per concern so edges and cards read as a single system
# ==============================================================================

NAVY = "#1A2B4A"    # structure: region, VCN, cluster, ingress
BLUE = "#336791"    # the request path: load balancer, flask tier
GREEN = "#2F8F4E"   # identity: workload identity policy
AMBER = "#B5732E"   # the games tier
PURPLE = "#7A5CA6"  # control plane and autoscaling
TEAL = "#2E8B8B"    # persistence and registry: NoSQL, OCIR
GREY = "#5B6B82"    # subtitle text

BG_FLASK = "#F2F7FB"  # flask node pool tint
BG_GAMES = "#FDF6EE"  # game node pool tint
BG_PUB = "#F2F7FB"    # public subnet tint
BG_PRIV = "#F1F8F3"   # private subnet tint

# ==============================================================================
# Lucide icon paths — 24x24 viewBox, stroked (never filled) so the card's
# accent color carries through via the stroke parameter
# ==============================================================================

ICONS = {
    "cloud": '<path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"/>',
    "globe": '<circle cx="12" cy="12" r="10"/>'
             '<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>'
             '<path d="M2 12h20"/>',
    "terminal": '<polyline points="4 17 10 11 4 5"/>'
                '<line x1="12" x2="20" y1="19" y2="19"/>',
    "route": '<circle cx="6" cy="19" r="3"/>'
             '<path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15"/>'
             '<circle cx="18" cy="5" r="3"/>',
    "network": '<rect x="16" y="16" width="6" height="6" rx="1"/>'
               '<rect x="2" y="16" width="6" height="6" rx="1"/>'
               '<rect x="9" y="2" width="6" height="6" rx="1"/>'
               '<path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/>'
               '<path d="M12 12V8"/>',
    "code": '<path d="m18 16 4-4-4-4"/><path d="m6 8-4 4 4 4"/>'
            '<path d="m14.5 4-5 16"/>',
    "gamepad": '<line x1="6" x2="10" y1="11" y2="11"/>'
               '<line x1="8" x2="8" y1="9" y2="13"/>'
               '<line x1="15" x2="15.01" y1="12" y2="12"/>'
               '<line x1="18" x2="18.01" y1="10" y2="10"/>'
               '<path d="M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101'
               '-.017.152C2.604 9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 '
               '2-1l1.414-1.414A2 2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 '
               '18c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258'
               '-.007-.05-.011-.1-.017-.151A4 4 0 0 0 17.32 5z"/>',
    "database": '<ellipse cx="12" cy="5" rx="9" ry="3"/>'
                '<path d="M3 5V19A9 3 0 0 0 21 19V5"/>'
                '<path d="M3 12A9 3 0 0 0 21 12"/>',
    "package": '<path d="m7.5 4.27 9 5.15"/>'
               '<path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 '
               '0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 '
               '16Z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 22V12"/>',
    "shield": '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 '
              '18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 '
              '0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
    "server": '<rect width="20" height="8" x="2" y="2" rx="2" ry="2"/>'
              '<rect width="20" height="8" x="2" y="14" rx="2" ry="2"/>'
              '<line x1="6" x2="6.01" y1="6" y2="6"/>'
              '<line x1="6" x2="6.01" y1="18" y2="18"/>',
    "scaling": '<polyline points="22 7 13.5 15.5 8.5 10.5 2 17"/>'
               '<polyline points="16 7 22 7 22 13"/>',
    "swap": '<path d="M8 3 4 7l4 4"/><path d="M4 7h16"/>'
            '<path d="m16 21 4-4-4-4"/><path d="M20 17H4"/>',
    "cpu": '<rect width="16" height="16" x="4" y="4" rx="2"/>'
           '<rect width="6" height="6" x="9" y="9" rx="1"/>'
           '<path d="M15 2v2"/><path d="M15 20v2"/><path d="M2 15h2"/>'
           '<path d="M2 9h2"/><path d="M20 15h2"/><path d="M20 9h2"/>'
           '<path d="M9 2v2"/><path d="M9 20v2"/>',
    "cog": '<circle cx="12" cy="12" r="3"/>'
           '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 '
           '2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 '
           '2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 '
           '0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 '
           '2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 '
           '1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 '
           '0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15'
           '-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 '
           '0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/>',
    "calendar": '<path d="M8 2v4"/><path d="M16 2v4"/>'
                '<rect width="18" height="18" x="3" y="4" rx="2"/>'
                '<path d="M3 10h18"/>',
    "activity": '<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 '
                '0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 '
                '4.49 12H2"/>',
}


def icon_uri(name, color):
    """Return a draw.io image= data URI for a lucide glyph in `color`."""
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
        'viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2" '
        'stroke-linecap="round" stroke-linejoin="round">%s</svg>'
        % (color, ICONS[name])
    )
    return "data:image/svg+xml," + quote(svg, safe="")


def esc(html):
    """Escape an HTML label so it survives inside an XML value attribute."""
    return (html.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;"))


class Canvas:
    """Accumulates mxCell fragments for one diagram."""

    def __init__(self, name):
        self.name = name
        self.cells = []
        self.cells.append(
            '<mxCell id="frame" value="" style="rounded=0;fillColor=#FFFFFF;'
            'strokeColor=none;" vertex="1" parent="1">'
            '<mxGeometry x="0" y="0" width="1920" height="1080" as="geometry"/>'
            '</mxCell>'
        )

    def card(self, cid, x, y, w, h, color, icon, title, subs, title_note=""):
        """Emit a rounded accent-stroked card with icon, title and subtitles."""
        self.cells.append(
            '<mxCell id="%s" value="" style="rounded=1;whiteSpace=wrap;html=1;'
            'fillColor=#FFFFFF;strokeColor=%s;strokeWidth=2;" vertex="1" '
            'parent="1"><mxGeometry x="%d" y="%d" width="%d" height="%d" '
            'as="geometry"/></mxCell>' % (cid, color, x, y, w, h)
        )
        self.cells.append(
            '<mxCell id="%s_i" value="" style="shape=image;html=1;imageAspect=0;'
            'aspect=fixed;verticalAlign=middle;image=%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="52" height="52" as="geometry"/>'
            '</mxCell>' % (cid, icon_uri(icon, color), x + 24, y + h // 2 - 26)
        )
        note = ('  <span style="font-size:16px;color:%s">%s</span>'
                % (color, title_note)) if title_note else ""
        body = "".join(
            '<br><span style="font-size:15px;color:%s">%s</span>' % (GREY, s)
            for s in subs
        )
        label = '<b style="font-size:22px">%s</b>%s%s' % (title, note, body)
        self.cells.append(
            '<mxCell id="%s_t" value="%s" style="text;html=1;align=left;'
            'verticalAlign=middle;fillColor=none;strokeColor=none;fontColor=%s;" '
            'vertex="1" parent="1"><mxGeometry x="%d" y="%d" width="%d" '
            'height="%d" as="geometry"/></mxCell>'
            % (cid, esc(label), NAVY, x + 88, y + 10, w - 104, h - 20)
        )

    def container(self, cid, x, y, w, h, color, label, fill="none", fsize=18,
                  dash=False, icon=None):
        """Emit a grouping frame with a top-left label."""
        # Square corners on every frame — a percentage arc balloons on shapes
        # this large and reads as a blob rather than a boundary.
        style = (
            'rounded=0;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;'
            'strokeWidth=%s;fontColor=%s;align=left;verticalAlign=top;'
            'spacingTop=12;spacingLeft=%d;fontStyle=1;fontSize=%d;%s'
            % (fill, color, "2.5" if dash else "2", color,
               58 if icon else 20, fsize,
               "dashed=1;dashPattern=8 6;" if dash else "")
        )
        self.cells.append(
            '<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/>'
            '</mxCell>' % (cid, label, style, x, y, w, h)
        )
        if icon:
            self.cells.append(
                '<mxCell id="%s_i" value="" style="shape=image;html=1;'
                'imageAspect=0;aspect=fixed;verticalAlign=middle;image=%s" '
                'vertex="1" parent="1"><mxGeometry x="%d" y="%d" width="34" '
                'height="34" as="geometry"/></mxCell>'
                % (cid, icon_uri(icon, color), x + 16, y + 14)
            )

    def edge(self, cid, src, dst, label, color, ex, ey, nx, ny, dash=False,
             width="2.5", lpos=None):
        """Emit a labelled orthogonal edge between two card ids.

        Args:
            lpos: Optional position of the label along the edge, -1 at the
                source and 1 at the target. draw.io centres labels by default,
                which on a long dog-legged edge drops the text wherever the
                midpoint happens to land — often on top of a frame label.
        """
        style = (
            'edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;strokeColor=%s;'
            'strokeWidth=%s;fontColor=%s;fontSize=16;fontStyle=1;'
            'endArrow=classic;exitX=%s;exitY=%s;exitDx=0;exitDy=0;entryX=%s;'
            'entryY=%s;entryDx=0;entryDy=0;labelBackgroundColor=#FFFFFF;%s'
            % (color, width, color, ex, ey, nx, ny, "dashed=1;" if dash else "")
        )
        geo = ('<mxGeometry x="%s" relative="1" as="geometry"/>' % lpos
               if lpos is not None
               else '<mxGeometry relative="1" as="geometry"/>')
        self.cells.append(
            '<mxCell id="%s" value="%s" style="%s" edge="1" parent="1" '
            'source="%s" target="%s">%s</mxCell>'
            % (cid, label, style, src, dst, geo)
        )

    def note(self, cid, x, y, w, h, text, color=GREY, size=16):
        """Free-floating annotation text.

        whiteSpace=wrap is load-bearing: without it draw.io lays the string out
        on a single line that runs across the canvas and through every card in
        its path.
        """
        self.cells.append(
            '<mxCell id="%s" value="%s" style="text;html=1;whiteSpace=wrap;'
            'align=left;verticalAlign=top;fillColor=none;strokeColor=none;'
            'fontColor=%s;fontSize=%d;fontStyle=2;" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/>'
            '</mxCell>' % (cid, esc(text), color, size, x, y, w, h)
        )

    def write(self, path):
        doc = (
            '<mxfile host="app.diagrams.net">'
            '<diagram name="%s">'
            '<mxGraphModel dx="1920" dy="1080" grid="0" gridSize="10" guides="1" '
            'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
            'pageWidth="1920" pageHeight="1080" math="0" shadow="0">'
            '<root><mxCell id="0"/><mxCell id="1" parent="0"/>'
            % self.name
            + "".join(self.cells) +
            '</root></mxGraphModel></diagram></mxfile>'
        )
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(doc)
        print("wrote", path, len(doc), "bytes")


# ==============================================================================
# Diagram 1 — the traffic path
# ------------------------------------------------------------------------------
# One public address reaches everything. The point of the layout is that there
# is exactly one load balancer and one ingress in front of two node pools, and
# nothing between the cluster and the load balancer — no controller to install,
# because OKE's cloud controller manager creates it.
# ==============================================================================

def build_arch():
    c = Canvas("oci-k8s")

    c.card("internet", 40, 490, 210, 130, NAVY, "globe",
           "Internet", ["browser", "HTTP :80"])

    c.container("region", 280, 55, 1590, 975, NAVY,
                "OCI Region  —  us-ashburn-1", dash=True, fsize=24, icon="cloud")

    c.card("lb", 310, 460, 310, 150, BLUE, "route",
           "OCI Load Balancer",
           ["created by the cluster itself", "k8s-lb-subnet · flexible 10–100"])

    c.container("cluster", 680, 95, 800, 900, NAVY,
                "OKE Cluster  —  flask-oke-cluster  ·  ENHANCED", fsize=20,
                icon="server")

    c.card("ingress", 690, 460, 290, 150, NAVY, "network",
           "NGINX Ingress", ["one entry point", "routes by path"])

    c.container("pool_flask", 1020, 150, 430, 300, BLUE,
                "Node pool: flask-nodes  ·  1 → 4", fill=BG_FLASK, fsize=17)
    c.card("flask", 1040, 240, 390, 150, BLUE, "code",
           "flask-app", ["2 replicas · HPA to 5", "runs as nosql-access-sa"])

    c.container("pool_games", 1020, 620, 430, 300, AMBER,
                "Node pool: game-nodes  ·  fixed at 1", fill=BG_GAMES, fsize=17)
    c.card("games", 1040, 710, 390, 150, AMBER, "gamepad",
           "tetris · breakout · frogger",
           ["1 replica each", "/games/*"])

    c.card("ocir", 1520, 180, 330, 150, TEAL, "package",
           "OCIR", ["flask-app · games", "private · pull secret"])

    c.card("nosql", 1520, 460, 330, 150, TEAL, "database",
           "NoSQL: Candidates", ["shard key CandidateName", "50 read/write units"])

    c.card("wi", 1520, 740, 330, 150, GREEN, "shield",
           "Workload Identity",
           ["nosql-access-sa", "no key, no config file"])

    c.edge("e_in", "internet", "lb", "HTTP", BLUE, "1", "0.5", "0", "0.5")
    c.edge("e_np", "lb", "ingress", "NodePort", BLUE, "1", "0.5", "0", "0.5")
    c.edge("e_api", "ingress", "flask", "/flask-app/api", BLUE,
           "1", "0.3", "0", "0.5")
    c.edge("e_game", "ingress", "games", "/games", AMBER,
           "1", "0.7", "0", "0.5")
    c.edge("e_db", "flask", "nosql", "query · update_row", TEAL,
           "1", "0.75", "0", "0.25")
    c.edge("e_pull1", "ocir", "flask", "image pull", TEAL,
           "0", "0.5", "1", "0.25", dash=True)
    # The policy points at the table it governs. Routing it to the pod
    # instead meant a long dashed line back across the corridor, stacked on
    # top of the image pull and the query.
    c.edge("e_wi", "wi", "nosql", "authorizes nosql-rows", GREEN,
           "0.5", "0", "0.5", "1", dash=True)

    c.note("n1", 310, 660, 310, 120,
           "No load balancer controller. OKE's cloud controller manager "
           "creates the balancer for a Service of type LoadBalancer — the "
           "chart and IAM policy the AWS build needed have no counterpart.")

    c.write(os.path.join(HERE, "oci-k8s.drawio"))


# ==============================================================================
# Diagram 2 — the network
# ------------------------------------------------------------------------------
# The AWS original drew two public and two private subnets, one pair per
# availability zone. OCI subnets are regional, so the same design needs three
# subnets split by role and the AZ pairing disappears. That is the shape.
# ==============================================================================

def build_infra():
    c = Canvas("oci-k8s-infra")

    c.card("kubectl", 40, 300, 220, 130, PURPLE, "terminal",
           "kubectl", ["oci ce cluster", "generate-token"])
    c.card("internet", 40, 640, 220, 130, NAVY, "globe",
           "Internet", ["HTTP :80"])

    c.container("region", 290, 55, 1580, 975, NAVY,
                "OCI Region  —  us-ashburn-1", dash=True, fsize=24, icon="cloud")

    c.card("cp", 380, 110, 420, 130, PURPLE, "cloud",
           "OKE Control Plane", ["Oracle-managed", "no nodes you run or patch"])

    c.container("vcn", 330, 285, 1160, 715, NAVY,
                "VCN  —  k8s-vcn  ·  10.0.0.0/24", fsize=20, icon="network")

    c.container("sn_api", 360, 350, 330, 185, BLUE,
                "k8s-api-subnet  ·  public", fill=BG_PUB, fsize=15)
    c.card("api", 380, 410, 290, 110, BLUE, "route",
           "API endpoint", ["10.0.0.0/28 · :6443"])

    c.container("sn_lb", 360, 570, 330, 185, BLUE,
                "k8s-lb-subnet  ·  public", fill=BG_PUB, fsize=15)
    c.card("lb", 380, 630, 290, 110, BLUE, "route",
           "Load Balancer", ["10.0.0.16/28 · :80"])

    c.container("sn_node", 740, 350, 720, 405, GREEN,
                "k8s-node-subnet  ·  private  ·  10.0.0.128/25",
                fill=BG_PRIV, fsize=15)
    c.card("np_flask", 770, 420, 660, 130, BLUE, "server",
           "flask-nodes", ["VM.Standard.E5.Flex · 2 OCPU / 16 GB",
                           "autoscaler resizes 1 → 4"])
    c.card("np_games", 770, 590, 660, 130, AMBER, "server",
           "game-nodes", ["VM.Standard.E5.Flex · 2 OCPU / 16 GB",
                          "fixed at 1 — never scaled"])

    c.card("gw_i", 360, 800, 340, 120, NAVY, "globe",
           "Internet GW", ["public subnets"])
    c.card("gw_n", 730, 800, 340, 120, NAVY, "swap",
           "NAT GW", ["node egress"])
    c.card("gw_s", 1100, 800, 340, 120, TEAL, "swap",
           "Service GW", ["OCIR over the backbone"])

    c.card("ocir", 1530, 350, 320, 150, TEAL, "package",
           "OCIR", ["flask-app · games", "pulled via Service GW"])
    c.card("nosql", 1530, 570, 320, 150, TEAL, "database",
           "NoSQL: Candidates", ["workload identity", "no key on the node"])

    c.edge("e_kube", "kubectl", "api", ":6443", PURPLE, "1", "0.5", "0", "0.5")
    c.edge("e_net", "internet", "lb", ":80", BLUE, "1", "0.5", "0", "0.5")
    # Drops through the 50px corridor between the api subnet (ends x=690)
    # and the node subnet (starts x=740). Straight down from the card centre
    # crossed the VCN frame label; further right put the edge inside the node
    # subnet, which read as the control plane connecting via the workers.
    c.edge("e_cp", "cp", "api", "public endpoint", PURPLE,
           "0.8", "1", "1", "0.5", dash=True, lpos="-0.75")
    c.edge("e_lbn", "lb", "np_flask", "NodePort", BLUE, "1", "0.3", "0", "0.5")
    c.edge("e_lbg", "lb", "np_games", "", AMBER, "1", "0.7", "0", "0.5")
    c.edge("e_pull", "ocir", "np_flask", "image pull", TEAL,
           "0", "0.5", "1", "0.3", dash=True)
    c.edge("e_db", "np_flask", "nosql", "query", TEAL, "1", "0.7", "0", "0.3")

    c.note("n2", 330, 940, 1160, 50,
           "Three subnets, split by role. OCI subnets are REGIONAL — one "
           "already spans every availability domain, so the AWS design's "
           "zonal pairs collapse to one subnet each.")

    c.write(os.path.join(HERE, "oci-k8s-infra.drawio"))


# ==============================================================================
# Diagram 3 — the control plane
# ------------------------------------------------------------------------------
# Ports the component breakdown from the AWS original, which drew the six
# Kubernetes control plane pieces as an icon grid. The point of redrawing it
# for OCI is what the boundary means: every component in the top frame exists
# and runs, and none of them is a node you provision, patch or pay for by the
# hour. That is the whole of "managed".
#
# Two additions the AWS diagram had no reason to make:
#   - the CLOUD CONTROLLER MANAGER, which is why this project installs no load
#     balancer controller
#   - the ENHANCED_CLUSTER card, because workload identity is a control plane
#     capability and a basic cluster simply does not have it
# ==============================================================================

def build_control_plane():
    c = Canvas("oci-k8s-control-plane")

    c.card("kubectl", 40, 300, 230, 150, PURPLE, "terminal",
           "kubectl", ["oci ce cluster", "generate-token"])

    c.note("n_you", 40, 640, 230, 200,
           "Everything you actually operate is in the lower two frames. The "
           "upper frame is billed as part of the cluster and has no instance "
           "you can log in to.")

    c.container("region", 310, 55, 1560, 975, NAVY,
                "OCI Region  —  us-ashburn-1", dash=True, fsize=24, icon="cloud")

    # --------------------------------------------------------------------------
    # Oracle-managed control plane
    # --------------------------------------------------------------------------
    c.container("cp", 350, 110, 700, 530, PURPLE,
                "Oracle-Managed Control Plane", fill="#F7F4FB", fsize=19,
                icon="cloud")

    c.card("apiserver", 530, 175, 340, 120, PURPLE, "route",
           "kube-apiserver", ["the only public endpoint"])
    c.card("etcd", 380, 330, 310, 115, PURPLE, "database",
           "etcd", ["cluster state"])
    c.card("sched", 710, 330, 310, 115, PURPLE, "calendar",
           "kube-scheduler", ["places pods on nodes"])
    c.card("ctrlmgr", 380, 470, 310, 115, PURPLE, "cog",
           "controller-manager", ["reconciles"])
    c.card("ccm", 710, 470, 310, 115, TEAL, "cloud",
           "cloud-controller-manager", ["creates the OCI LB"])

    # --------------------------------------------------------------------------
    # What actually runs on the workers
    # --------------------------------------------------------------------------
    c.container("worker", 350, 690, 700, 310, BLUE,
                "On Every Worker Node  —  both pools", fill=BG_FLASK, fsize=19,
                icon="server")

    c.card("kubelet", 380, 755, 310, 110, BLUE, "cpu",
           "kubelet", ["reports to apiserver"])
    c.card("kproxy", 710, 755, 310, 110, BLUE, "swap",
           "kube-proxy", ["NodePort rules"])
    c.card("flannel", 380, 880, 310, 105, BLUE, "share",
           "flannel", ["pod overlay"])
    c.card("runtime", 710, 880, 310, 105, BLUE, "package",
           "cri-o", ["pulls from OCIR"])

    # --------------------------------------------------------------------------
    # Add-ons — pods, not control plane. The distinction matters: these are
    # yours to upgrade and they consume worker capacity.
    # --------------------------------------------------------------------------
    c.container("addons", 1100, 110, 750, 530, AMBER,
                "Cluster Add-ons  —  pods on the workers, installed by Helm",
                fill=BG_GAMES, fsize=19, icon="package")

    c.card("ingress", 1130, 185, 690, 125, NAVY, "network",
           "ingress-nginx", ["its Service is type LoadBalancer",
                             "which is what the CCM acts on"])
    c.card("metrics", 1130, 335, 690, 125, AMBER, "activity",
           "metrics-server", ["supplies CPU to the HPA",
                              "not preinstalled on OKE"])
    c.card("autoscaler", 1130, 485, 690, 125, AMBER, "scaling",
           "cluster-autoscaler", ["resizes flask-nodes 1 to 4",
                                  "authenticates as the node instance"])

    c.card("enhanced", 1130, 700, 690, 140, GREEN, "shield",
           "ENHANCED_CLUSTER", ["issues workload principal tokens",
                                "a basic cluster cannot — no OIDC equivalent"])

    c.note("n_cp", 1100, 870, 750, 130,
           "No load balancer controller appears in the add-ons. The "
           "cloud-controller-manager is already inside the control plane, so "
           "the chart and IAM policy the AWS build installed have nothing to "
           "do here.")

    c.edge("e_kubectl", "kubectl", "apiserver", ":6443", PURPLE,
           "1", "0.5", "0", "0.5")
    c.edge("e_state", "etcd", "apiserver", "state", PURPLE,
           "0.5", "0", "0.25", "1", dash=True)
    c.edge("e_kubelet", "apiserver", "kubelet", "watch · exec · logs", BLUE,
           "0.25", "1", "0.5", "0", dash=True, lpos="0.6")

    c.write(os.path.join(HERE, "oci-k8s-control-plane.drawio"))


build_arch()
build_infra()
build_control_plane()
