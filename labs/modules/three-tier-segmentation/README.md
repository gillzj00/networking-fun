# Lab #2 — `three-tier-segmentation`

Three private subnets — `web`, `app`, `db` — each with one SSM-attached
`t4g.nano`. SGs chained by reference (not CIDR):

- `web-sg` accepts `tcp/443` from `0.0.0.0/0` (simulated ALB ingress).
- `app-sg` accepts `tcp/8080` from `web-sg`.
- `db-sg` accepts `tcp/5432` from `app-sg`.

Egress on each tier SG allows 443 to the SSM endpoint SG plus the destination
port on every other tier SG, so probe failures never reflect same-side egress
restrictions. One shared route table, no IGW, no NAT. Three SSM-family
interface endpoints provide control-plane reachability.

The probe Lambda calls `ssm:SendCommand` on each tier to run
`nc -zv -w 5 <peer> <port>`, producing a 3×3 source-by-destination matrix
rendered as a grid in the PR comment.

## Scenarios

| scenario | what it changes | the lesson |
|---|---|---|
| `happy-path` | nothing | Chained SG references confine traffic to web→app→db. |
| `cidr-instead-of-sg` | `db-sg` allows the VPC CIDR on `5432` instead of `app-sg`. | CIDR-based rules widen blast radius; web now reaches db. |
| `nacl-stateless-return` | Custom NACL on db subnet allows ingress all, egress 443/5432/8080, **denies** TCP 32768–60999. | NACLs are stateless: SG approves `app→db:5432` (SYN reaches db), NACL drops the return SYN-ACK to app's ephemeral port. |
| `missing-chain-link` | `app-sg` omits the 8080 ingress rule from `web-sg`. | One missing hop breaks the chain — web can't reach app even with everything else correct. |

## Expected probe matrix

Passing cells in **bold**.

| scenario | web→app | web→db | app→web | app→db | db→web | db→app |
|---|---|---|---|---|---|---|
| `happy-path` | **pass** | fail | **pass** | **pass** | **pass** | fail |
| `cidr-instead-of-sg` | **pass** | **pass** | **pass** | **pass** | **pass** | fail |
| `nacl-stateless-return` | **pass** | fail | **pass** | fail | **pass** | fail |
| `missing-chain-link` | fail | fail | **pass** | **pass** | **pass** | fail |

The `app→web` and `db→web` rows pass in every scenario because `web-sg` allows
`tcp/443` from `0.0.0.0/0` — the takeaway is that an overly broad inbound rule
on the web tier swallows what would otherwise be useful negative signal.
