# 09 Yocto-built builder experiment

Status: **planned**. Reference: Tim Orling, "Signed, Sealed, Delivered: Yocto Project Reference Containers"
(OSS EU 2026). Uses `image-oci`, `OCI_LAYERS`, SPDX 3.0 SBOM from the build, cosign signing.

Goal: build an equivalent builder image with bitbake (via kas) and compare against the Debian builder:
contents, size, SBOM completeness, reproducibility, signing path. Not production until upstream ships a
`container-yocto-builder` and the comparison is favourable. The publish/sign/verify chapters apply unchanged
(they take an image digest).
