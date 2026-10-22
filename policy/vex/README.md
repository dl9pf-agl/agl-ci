# VEX waivers

One `*.openvex.json` file per waiver (or per topic). Every file is applied automatically by `scripts/cve-scan.sh`
and listed in the report. Playbook: `docs/manual/12-vex-playbook.md`. Start from `TEMPLATE.openvex.json.example`
(rename to `<topic>.openvex.json`). Files without the `.openvex.json` suffix are ignored.
