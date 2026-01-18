#!/bin/bash
# Garage Cluster Initialization Script
# Run this script after first boot to initialize the Garage single-node cluster
set -euo pipefail

GARAGE_CMD="podman exec -it garage /garage"

echo "=== Garage Cluster Initialization ==="
echo ""
echo "This script will initialize your Garage single-node cluster."
echo "It performs the following steps:"
echo "  1. Display the current node information"
echo "  2. Configure the node with a zone and capacity"
echo "  3. Apply the cluster layout"
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r

# Get node ID
echo ""
echo "Step 1: Getting node information..."
NODE_INFO=$(${GARAGE_CMD} node id)
echo "${NODE_INFO}"

NODE_ID=$(echo "${NODE_INFO}" | awk '{print $1}')
echo ""
echo "Node ID: ${NODE_ID}"

# Configure node with capacity (100GB by default, adjust as needed)
echo ""
echo "Step 2: Configuring node..."
echo "Setting zone=local and capacity=100GB (adjust capacity as needed)"
${GARAGE_CMD} layout assign "${NODE_ID}" -z local -c 100G

# Show layout before applying
echo ""
echo "Current layout (before applying):"
${GARAGE_CMD} layout show

# Apply layout
echo ""
echo "Step 3: Applying layout..."
${GARAGE_CMD} layout apply --version 1

echo ""
echo "=== Initialization Complete ==="
echo ""
echo "Your Garage cluster is now ready!"
echo ""
echo "Next steps:"
echo "  1. Create a key pair: podman exec -it garage /garage key create my-key"
echo "  2. Create a bucket: podman exec -it garage /garage bucket create my-bucket"
echo "  3. Allow the key to access the bucket: podman exec -it garage /garage bucket allow my-bucket --read --write --key my-key"
echo "  4. Get the key credentials: podman exec -it garage /garage key info my-key"
echo ""
echo "Access endpoints:"
echo "  S3 API: https://s3.i.samhclark.com"
echo "  Admin API: https://garage.i.samhclark.com"
echo ""
