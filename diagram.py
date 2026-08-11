"""Architecture diagram for gcp-supply-chain-security.

Renders docs/architecture.png using the official GCP icon set.

    pip install diagrams   # requires graphviz: brew install graphviz
    python diagram.py

Organized around the trust boundary rather than around the pipeline. A left to
right build diagram would make this look like every other CI picture, and the
only thing that matters here is which project holds the key and which project
holds the policy. So the two projects are the frame, the arrows that cross
between them are labelled with what crosses, and the two denials are drawn as
denials rather than left implied.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.compute import ComputeEngine, Run
from diagrams.gcp.devtools import Build, ContainerRegistry
from diagrams.gcp.security import KMS, SecurityScanner

GRAPH_ATTR = {
    "fontsize": "16",
    "labelloc": "t",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.7",
    "ranksep": "1.1",
    "bgcolor": "transparent",
}

SIGN = {"color": "darkgreen", "style": "bold"}
DENY = {"color": "firebrick", "style": "bold"}
FLOW = {"color": "dimgray"}
VERIFY = {"color": "darkblue", "style": "dashed"}

with Diagram(
    "GCP Supply Chain Security",
    filename="docs/architecture",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    with Cluster("build project"):
        build = Build("Cloud Build\nuser-managed SA")
        registry = ContainerRegistry("Artifact Registry")
        scan = SecurityScanner("Artifact Analysis\non-demand scan")
        key = KMS("Asymmetric key\nsign only")
        packer = ComputeEngine("Packer bake\nimage family")

    with Cluster("runtime project"):
        policy = SecurityScanner("Binary Authorization\nREQUIRE_ATTESTATION")
        run = Run("Cloud Run")
        vm = ComputeEngine("Compute Engine")

    unsigned = ContainerRegistry("Unsigned digest")
    stock = ComputeEngine("Stock public image")

    # The happy path. Every arrow here is a precondition for the next one.
    build >> Edge(**FLOW, label="push") >> registry
    registry >> Edge(**FLOW, label="digest") >> scan
    scan >> Edge(**SIGN, label="clean") >> key
    key >> Edge(**SIGN, label="attestation") >> policy
    policy >> Edge(**SIGN, label="admit") >> run

    # The cross-project grant that makes the split work: the policy can read the
    # attestor to verify, and has no path to the key that signs.
    policy >> Edge(**VERIFY, label="verify only\nno sign access") >> key

    # Denial one: a real image in the real registry, without a signature.
    unsigned >> Edge(**DENY, label="no attestation\nblocked") >> policy

    # Denial two: the same idea at the VM layer, enforced on the image's project
    # rather than on a signature.
    packer >> Edge(**SIGN, label="image family") >> vm
    stock >> Edge(**DENY, label="trustedImageProjects\nblocked") >> vm
