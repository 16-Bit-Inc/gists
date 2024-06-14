## Installation Instructions (Linux):

Simple installation
```bash
RHO_CUSTOMER_NAME=<customer-name> \
RHO_GHCR_KEY=<key> \
bash <(curl -fsSL https://raw.githubusercontent.com/16-Bit-Inc/gists/main/install-rho.sh)
```

Different options
```bash
DATA_DIR=<data directory for k3s installation and storing the container images> \
MIN_DISK=80 \
MIN_RAM=7 \
RHO_CUSTOMER_NAME=<customer-name> \
RHO_GHCR_KEY=<key> \
bash <(curl -fsSL https://raw.githubusercontent.com/16-Bit-Inc/gists/main/install-rho.sh)
```

- Use the `DATA_DIR` option when the customer wants to install Rho at a different location.
- The `MIN_DISK` and `MIN_RAM` values are in GBs.
