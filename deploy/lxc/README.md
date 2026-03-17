# LXC Deployment Notes

- Use unprivileged containers only.
- Run Phoenix/worker nodes behind a reverse proxy with TLS termination.
- Persist PostgreSQL and uploaded artifacts outside ephemeral rootfs.
- Prefer dedicated LXC containers per service role in enterprise setups.
