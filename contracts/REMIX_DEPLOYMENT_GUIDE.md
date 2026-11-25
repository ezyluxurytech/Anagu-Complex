# ANAGU Smart Contracts — Direct Remix IDE Deployment Guide (No Hardhat)

Both ANAGU smart contracts are **100% standalone, zero-dependency Solidity files** — no Hardhat, no `npm install`, and no external OpenZeppelin imports needed.

- **`contracts/AnaguToken.sol`** (`ANAGU` ERC-20) — Statutory registration filing fee (`payLandRegistrationFee`), Registrar-controlled land purchase escrow (`openPurchaseEscrow` / `releasePurchaseEscrow` / `refundPurchaseEscrow`), and testnet faucet (`claimTestnetFaucet`).
- **`contracts/AnaguLandTitleNFT.sol`** (`ANAGU-TITLE` ERC-721) — Mandatory Community Oracle attestation (`recordOracleAttestation`), Registrar title issuance (`mintTitle`), P2P transfer lock + Registrar-controlled `registryTransfer`, and Section 28 Governor revocation (`revokeTitle`).

---

## Step 1: Prepare MetaMask for Polygon Amoy Testnet
1. Open MetaMask and switch to **Polygon Amoy Testnet**:
   - **Network Name:** `Polygon Amoy Testnet`
   - **RPC URL:** `https://rpc-amoy.polygon.technology`
   - **Chain ID:** `80002`
   - **Currency Symbol:** `POL`
   - **Block Explorer:** `https://amoy.polygonscan.com`
2. Get free testnet `POL` gas tokens at https://faucet.polygon.technology/ (select **Polygon Amoy**).

*(For local Hyperledger Besu QBFT instead, switch MetaMask to Chain ID `13371`, RPC `http://127.0.0.1:8545`, and select EVM Version `paris` in Step 3.)*

---

## Step 2: Open Both Contracts in Remix IDE
1. Go to https://remix.ethereum.org.
2. Create two files in Remix (or upload them from `/contracts/`):
   - `AnaguToken.sol`
   - `AnaguLandTitleNFT.sol`

---

## Step 3: Compile in Remix
Open the **Solidity Compiler** tab:
- **Compiler:** `0.8.24` (or any `0.8.20+` release)
- **Optimization:** Enabled, `200` runs
- **EVM Version:** `default` (or `paris` if deploying to local Besu QBFT)
- Click **Compile AnaguToken.sol** and **Compile AnaguLandTitleNFT.sol** — both compile with zero external imports and zero errors.

---

## Step 4: Deploy via `Injected Provider - MetaMask`
Open the **Deploy & Run Transactions** tab and set **Environment** to **`Injected Provider - MetaMask`** (confirm it shows `Custom (80002) network`).

### 1. Deploy `AnaguToken`
Fill in the constructor fields (whole tokens — no 18-zero wei conversion needed):
- `initialAdmin`: your wallet `0x...` *(or `0x0000000000000000000000000000000000000000` to auto-use your connected wallet)*
- `initialRegistrar`: your wallet `0x...` *(or `0x0000000000000000000000000000000000000000` to auto-use `initialAdmin`)*
- `initialTreasury`: your wallet `0x...` *(or `0x0000000000000000000000000000000000000000` to auto-use `initialAdmin`)*
- `initialSupplyTokens`: `10000000` *(mints 10,000,000 ANAGU to treasury)*
- `initialRegFeeTokens`: `50` *(sets registration fee to 50 ANAGU)*
- `enableFaucet`: `true` *(set `false` for mainnet)*

Click **Deploy** and confirm in MetaMask. Copy the deployed `AnaguToken` address.

### 2. Deploy `AnaguLandTitleNFT`
Fill in the constructor fields:
- `initialAdmin`: your wallet `0x...` *(or `0x0000000000000000000000000000000000000000` to auto-use your connected wallet)*
- `initialRegistrar`: your wallet `0x...` *(or separate Registrar wallet)*
- `initialOracle`: your wallet `0x...` *(or separate Community Oracle wallet)*
- `initialGovernor`: your wallet `0x...` *(or separate Governor wallet)*

Click **Deploy** and confirm in MetaMask. Copy the deployed `AnaguLandTitleNFT` address.

---

## Step 5: Connect the Deployed Addresses to the App
Paste both `0x...` addresses into **Admin Portal → Polygon Amoy Smart Contracts → Configure Addresses** (or update `src/config/polygonAmoyDeployment.json` / `.env` variables `VITE_ANAGU_TOKEN_ADDRESS` and `VITE_ANAGU_LAND_TITLE_NFT_ADDRESS`).
