# 12 VEX playbook: waiving a finding

Status: waiver mechanism **tested** (a synthetic statement removed exactly one finding and appeared in the report);
no real waiver exists yet. A waiver is a security decision: it needs a reviewer other than the author once the
team has two engineers (chapter 06, solo-approver note applies until then).

## When to waive, in order of preference
1. **Remove the cause**: drop the package, bump the pin (chapter 08). Prefer this.
2. **Wait for upstream**: finding is `not-fixed`/`wont-fix` and the bar uses `ONLY_FIXED=true`: no waiver needed, it stays in the report.
3. **Waive with evidence**: the code path is provably not reachable or the product is not affected.
4. **Never waive** because the report is inconvenient.

## Steps
1. Find the finding in `cve-build.json` (`artifact.purl`, `vulnerability.id`).
2. Decide the status (OpenVEX): `not_affected` (needs a justification), `fixed`, `under_investigation`, `affected` (with action).
   Justifications: `component_not_present`, `vulnerable_code_not_present`, `vulnerable_code_not_in_execute_path`,
   `vulnerable_code_cannot_be_controlled_by_adversary`, `inline_mitigations_already_exist`.
3. `cp policy/vex/TEMPLATE.openvex.json.example policy/vex/<CVE-id>.openvex.json`, fill in id, author, timestamp,
   product purl (copy it from the finding, exact string), status, justification, `impact_statement` (verifiable
   reason, source link, date, re-review trigger such as "when package > X").
4. Verify locally: `scripts/cve-scan.sh oci-archive:builder.tar build out/` - the count drops by the waived
   finding(s) and the file is listed under "Waivers".
5. PR with the file. Reviewer checks the reasoning, not just the format. Merge.
6. Waivers expire by review: each statement states its re-review trigger; the weekly re-scan (chapter 10) shows
   waivers whose package version changed, because the purl no longer matches and the finding returns.

## Match rules (observed)
Statements match by exact package purl including version and distro; a new package version means the finding
reappears and the waiver must be re-evaluated. This is intentional.

## Responding to a published advisory (checklist)
Examples seen on 2026-10-22: Debian DSA-6572-1 (`ca-certificates`, eMudhra intermediate CA compromise),
PHP CVE-2026-109618/109619, Node.js CVE-2026-105483/106069/111497.
1. Are we exposed? `grep` the id in the latest `cve-build.json`, check the package is in the SBOM
   (`python3 -I -c` over the SPDX file, or `scripts/cve-scan.sh registry:<ref>@<digest> release out/`).
2. A CVE id absent from the scan can mean: package not present, scanner DB not updated yet, or id not published
   in NVD/distro feeds yet (several 2026 ids were not yet resolvable). State which one in the incident note.
3. Fix = new pin (`SNAPSHOT`, runner version), PR, rebuild, release; or waive with evidence (above).
4. Record in the release notes; for CRA reporting duties see chapter 07.
