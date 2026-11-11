# Architecture

This document explains the Platform-Managed EFA Runtime design in detail: what runs where, why each step is needed, and how to make the proof of concept production ready.

## Goal

Decouple the **AWS network stack** (EFA user-space libraries, libfabric, aws-ofi-nccl, OpenMPI) from the **application image**. The platform team owns the network stack and delivers it to pods when they start. Application teams ship images that contain only their framework, CUDA, and NCCL.

## Components

```
┌──────────────────────────── Pod ─────────────────────────────┐
│                                                              │
│  initContainer: efa-installer          volume: efa-libs      │
│  (amazonlinux:2023)                    (emptyDir)            │
│  mount: efa-libs -> /opt/amazon  ───►  efa/                  │
│  1. yum install prerequisites          ├── bin/fi_info       │
│  2. efa_installer.sh -y -k             ├── lib64/            │
│  3. cp rdma-core + libnl ──────────►   │   ├── libfabric*    │
│                                        │   ├── libfabric/    │
│                                        │   │   (providers)   │
│                                        │   ├── libefa*       │
│                                        │   ├── libibverbs*   │
│                                        │   ├── librdmacm*    │
│                                        │   └── libnl-*       │
│                                        ├── ofi-nccl/         │
│                                        └── openmpi/          │
│                                              │               │
│  container: worker (any image)               │ subPath,      │
│  /opt/amazon/efa       ◄─────────────────────┤ readOnly      │
│  /opt/amazon/ofi-nccl  ◄─────────────────────┤               │
│  /opt/amazon/openmpi   ◄─────────────────────┘               │
│  env: FI_PROVIDER=efa, FI_PROVIDER_PATH=..., LD_LIBRARY_PATH │
│  resources: nvidia.com/gpu, vpc.amazonaws.com/efa, hugepages │
└──────────────────────────────────────────────────────────────┘
          │ shares host kernel (EFA driver loaded by AMI)
          ▼
   Node: EFA kernel driver + EFA device plugin + NVIDIA device plugin
```

### Init container

- **Image:** `public.ecr.aws/amazonlinux/amazonlinux:2023`, a minimal image.
- **Prerequisites:** `tar gzip libatomic util-linux findutils which`, installed with `--allowerasing` so that yum can replace any conflicting minimal packages that ship in the base image.
- **Installer flags:**
  - `-y`: non-interactive.
  - `-k`: skip the kernel module. The node AMI already loads the EFA driver, and containers share the host kernel, so only user space is needed.
- **Volume mount:** the whole `efa-libs` volume at `/opt/amazon`. The installer's default prefix therefore writes directly onto the shared volume.
- **Resources:** `2–4` CPU and `4–8 GiB` memory, enough for the installer's package operations.

### Why copy rdma-core and netlink

The EFA libfabric provider (`libefa-fi.so`) depends on:

| Library | Package | Purpose |
|---|---|---|
| `libibverbs` | rdma-core | Verbs API used to talk to the EFA device |
| `librdmacm` | rdma-core | RDMA connection manager |
| `libefa` | rdma-core | EFA verbs provider |
| `libnl-3`, `libnl-route-3` | libnl3 | Netlink, used by rdma-core |

The installer puts these in `/usr/lib64` inside the init container. That path is **not** on the shared volume. Copying them into `/opt/amazon/efa/lib64` makes the volume self-contained, so the user container does not need rdma-core installed. Without the copy, NCCL fails to initialize the network plugin.

### User container

- **SubPath mounts instead of one mount at `/opt/amazon`.** Mounting the whole `emptyDir` at `/opt/amazon` would hide anything the image already keeps there. Mounting only `efa`, `ofi-nccl`, and `openmpi` replaces exactly those directories.
- **Read-only.** The application cannot change the platform-provided stack.
- **Environment:**
  - `FI_PROVIDER=efa` makes libfabric use the EFA provider instead of auto-detecting one. Auto-detection could pick TCP, sockets, or verbs if the EFA device isn't enumerable yet.
  - `FI_PROVIDER_PATH=/opt/amazon/efa/lib64/libfabric` is needed because libfabric's default provider search path is `/usr/lib64/libfabric/`. Without it, the provider isn't found and libfabric falls back to sockets.
  - `LD_LIBRARY_PATH` and `PATH` list the platform directories first.
- **Device resources:** `vpc.amazonaws.com/efa: 32` on `p5.48xlarge` (all EFA interfaces), `nvidia.com/gpu: 8`, and `hugepages-2Mi`, which the EFA provider uses for registered memory.

### Launcher (MPIJob)

The MPI launcher only runs `mpirun` and doesn't need GPUs or EFA. In the validation test it used the OpenMPI already included in the `nccl-tests` image. On the workers, the platform-provided `ofi-nccl`, `efa`, and `openmpi` sub-paths replace whatever that image had at those paths, so the workers really run on the platform-provided stack. OpenMPI is configured to use TCP for its own control traffic (`--mca btl tcp,self`, `pml ^ucx`, `mtl ^ofi`). NCCL traffic goes over EFA through aws-ofi-nccl.

## Validation

| Item | Value |
|---|---|
| Platform | Amazon EKS |
| Instances | 2 × `p5.48xlarge` (8 × H100, 32 EFA interfaces each) |
| Workload | `nccl-tests` `all_reduce_perf -b 8 -e 1G -f 2 -g 1 -c 1 -n 50` |
| Ranks | 16 (`-np 16 -N 8`) |
| Goal | Show that the platform can deliver the EFA runtime, not tune performance |

## Productionizing

The proof of concept runs the full EFA installer every time a pod starts. Options for production, from least to most change:

1. **Pin versions.** Set `EFA_INSTALLER_VERSION` and pin the image tags, so every pod gets the same stack.
2. **Prebuilt platform image.** Build an image such as `efa-stack:<installer-version>` that already contains the `/opt/amazon/{efa,ofi-nccl,openmpi}` tree with rdma-core and libnl copied in. Use `scripts/provision-efa-runtime.sh` at build time. The init container then only runs `cp -a /stack/. /opt/amazon/`. That takes seconds, needs no internet access, and the image is versioned and scannable.
3. **Image volumes.** On Kubernetes versions that support [image volumes](https://kubernetes.io/docs/tasks/configure-pod-container/image-volumes/), mount the platform image directly as a read-only volume and drop the init container. *This has not been tested.*
4. **Automatic attachment.** Use a mutating admission webhook or a policy engine (for example Kyverno) to add the init container, volume, mounts, and environment variables to any pod that requests `vpc.amazonaws.com/efa`. Users then make no manifest changes at all.

## Compatibility notes

- The platform-provided binaries are built on Amazon Linux 2023. The user image needs a glibc at least as new as that one. Validate each base image family you support, such as Ubuntu 22.04 or Debian-based PyTorch images.
- The user image still provides CUDA, NCCL, and the framework. Only the AWS network stack comes from the platform.
- The aws-ofi-nccl plugin must be compatible with the NCCL version in the user image. Check the aws-ofi-nccl release notes when you bump the installer version.
