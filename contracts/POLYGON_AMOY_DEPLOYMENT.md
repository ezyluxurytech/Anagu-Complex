# Deploying ANAGU Smart Contracts to Polygon Amoy Testnet (Chain ID 80002)

All ANAGU smart contracts are standalone Solidity files ready for direct deployment in **Remix IDE** with MetaMask (no Hardhat or local Node tooling required).

## Contracts
1. **`contracts/AnaguToken.sol`** (`ANAGU` ERC-20) — Statutory land registration filing fee, Registrar-controlled purchase escrow, and testnet faucet.
2. **`contracts/AnaguLandTitleNFT.sol`** (`ANAGU-TITLE` ERC-721) — Mandatory Community Oracle attestation, Registrar title minting, P2P transfer lock, Registrar-controlled `registryTransfer`, and Section 28 Governor revocation.

## Quick Remix Steps
1. Switch MetaMask to **Polygon Amoy Testnet** (Chain ID `80002`, RPC `https://rpc-amoy.polygon.technology`) and claim free testnet `POL` from https://faucet.polygon.technology/.
2. Open https://remix.ethereum.org and upload `contracts/AnaguToken.sol` and `contracts/AnaguLandTitleNFT.sol`.
3. Compile both files with **Solidity `0.8.24`** (Optimization `200` runs). Zero external imports are required.
4. Deploy with **Injected Provider - MetaMask**:
   - **`AnaguToken`**: pass your wallet `0x...` for `initialAdmin`, `initialRegistrar`, `initialTreasury`, `10000000` for `initialSupplyTokens`, `50` for `initialRegFeeTokens`, and `true` for `enableFaucet`.
   - **`AnaguLandTitleNFT`**: pass your wallet `0x...` (or segregated institutional wallets) for `initialAdmin`, `initialRegistrar`, `initialOracle`, and `initialGovernor`.
5. Paste the two deployed `0x...` addresses into `src/config/polygonAmoyDeployment.json`, your environment variables (`VITE_ANAGU_TOKEN_ADDRESS` and `VITE_ANAGU_LAND_TITLE_NFT_ADDRESS`), or directly inside the **Admin Portal → Polygon Amoy Smart Contracts** panel.

See `contracts/REMIX_DEPLOYMENT_GUIDE.md` for full constructor details and verification steps.
