# SponsoredForwarder

**SponsoredForwarder** is an upgradeable smart contract that allows protocols and dApps to sponsor users’ gas fees via a dedicated sponsorship pool. This setup leverages EIP-2771 (trusted forwarder) principles for meta transactions and EIP-712 for secure signature verification, enabling a seamless “gasless” user experience. The repo is called Sponsored Txs for short. This works with any EVM compatitble blockchain, but it was first intended for use on the Base blockchain. 

---

## Overview

- **Upgradeable**  
  Uses OpenZeppelin’s upgradeable libraries and follows the UUPS proxy pattern, allowing the contract to be upgraded while preserving state.

- **Meta Transaction Forwarder**  
  Implements a `ForwardRequest` struct, secure signature verification (EIP‑712 compliant), and user-specific nonces to safely forward user transactions.

- **Sponsored Gas**  
  Maintains a `sponsorshipBalance` funded by the dApp/protocol, which covers relayers’ gas costs for executing meta transactions.

- **Relayer Authorization & Scheduled Governance**  
  Only authorized relayers can call the `execute` function. The owner can schedule and execute changes to relayer authorization and gas limit parameters, with a delay to allow for off-chain reviews.

- **Funding & Withdrawals**  
  Users can deposit ETH into the sponsorship pool via `fundSponsorship()`. The owner can withdraw funds (subject to a maximum withdrawal limit) using `withdrawSponsorship()`.

---

## Key Features

1. **Upgradeability**
   - Uses the UUPS upgradeable pattern.
   - Upgrades are restricted to the contract owner via the `_authorizeUpgrade()` function.

2. **Ownership**
   - Inherits from `OwnableUpgradeable` for easy ownership management.
   - Ownership is set during the `initialize()` call.

3. **Reentrancy Protection**
   - Uses `ReentrancyGuardUpgradeable` to protect critical functions (e.g., `execute`) against reentrancy attacks.

4. **EIP-2771 & EIP-712 Compliance**
   - **EIP-2771:** Functions as a trusted forwarder.
   - **EIP-712:** Implements domain separation and typed data hashing for robust signature verification.

5. **Scheduled Governance**
   - Functions `scheduleRelayerAuthorization` and `executeRelayerAuthorization` enable delayed changes to relayer statuses.
   - Functions `scheduleMaxGasLimit` and `executeMaxGasLimit` allow controlled updates to the maximum gas limit.

6. **Sponsorship Funding & Withdrawals**
   - `fundSponsorship()` allows deposit of ETH to cover gas fees.
   - `withdrawSponsorship()` lets the owner withdraw funds, ensuring withdrawals do not exceed a defined maximum amount.

---

## Contract Diagram

               ┌─────────────────────────────────┐
               │     dApp / Off-chain Relayer    │
               └─────────────┬───────────────────┘
                             │   Meta TX Request
                             ▼
                 ┌─────────────────────────┐
                 │ SponsoredForwarder      │
                 │ - OwnableUpgradeable    │
                 │ - ReentrancyGuard       │
                 │ - UUPSUpgradeable       │
                 └─────────────┬───────────┘
                             │  SponsorshipBalance,
                             │  AuthorizedRelayers, etc.
                             ▼
                 ┌─────────────────────────┐
                 │   Target Contract(s)    │
                 └─────────────────────────┘

---

## Installation and Setup

### 1. Install Dependencies

```bash
npm install @openzeppelin/contracts-upgradeable
npm install @openzeppelin/hardhat-upgrades
npm install @openzeppelin/hardhat-defender
npm install @openzeppelin/test-helpers
```

## 2. Compile

```bash 
npx hardhat compile
```

## 3. Deploy / Upgrade 

### Use the OpenZeppelin Hardhat Upgrades plugin to deploy the proxy:

```bash 
const { ethers, upgrades } = require("hardhat");

async function main() {
  const SponsoredForwarder = await ethers.getContractFactory("SponsoredForwarder");
  const forwarder = await upgrades.deployProxy(SponsoredForwarder, [], {
    kind: "uups",
  });
  await forwarder.deployed();
  console.log("SponsoredForwarder deployed at:", forwarder.address);
}

main();
```

### To upgrade the contract later:

```bash 
const forwarderV2 = await upgrades.upgradeProxy(forwarder.address, SponsoredForwarderV2);
console.log("Upgraded to V2 at:", forwarderV2.address);
```

## 4. Initialization

### The initialize() function is automatically called during proxy deployment if using the Hardhat Upgrades plugin. Otherwise, ensure you call initialize() once before any other interactions.

### Usage

1. Funding the Sponsorship Pool
Deposit ETH into the sponsorship pool:

```bash
await forwarder.fundSponsorship({ value: ethers.utils.parseEther("10") });
```
This deposits 10 ETH, increasing sponsorshipBalance.

2. Authorizing Relayers
3. 
Step 1: Schedule a relayer authorization change:

```bash
await forwarder.scheduleRelayerAuthorization(relayerAddress, true);
```

Step 2: After waiting for the required delay (CHANGE_DELAY), execute the change:

```bash
await forwarder.executeRelayerAuthorization(relayerAddress, true, scheduledTime);
```

Once authorized, a relayer can call execute() to forward meta transactions.

3. Executing Meta Transactions

Off-chain:
A user signs a ForwardRequest struct using the EIP-712 domain data.
The relayer collects the signature and transaction details.

On-chain:
The relayer calls execute(req, signature).
The contract verifies the signature and nonce, increments the nonce, and forwards the call to the target contract.
Gas costs are computed and deducted from the sponsorship pool; the relayer is reimbursed.

4. Withdrawing Sponsorship Funds
Only the owner can withdraw funds, subject to the maxWithdrawalAmount:

```bash
await forwarder.withdrawSponsorship(ethers.utils.parseEther("1"));
```

## Security Considerations

Nonce Management:
Each user’s nonce is tracked to prevent replay attacks.

Reentrancy Protection:
The execute() function is guarded by the nonReentrant modifier.

Gas Cost Reimbursement:
The contract calculates the relayer's gas usage and reimburses the gas cost from the sponsorship pool.

Upgradability Security:
The _authorizeUpgrade() function restricts upgrades to the owner.

Scheduled Governance:
Changes to relayer authorization and gas limit settings require a delay (CHANGE_DELAY), providing a window for review.

## Contributing

Fork the repository and create a new branch for your feature or bugfix.
Commit your changes, following best practices.
Submit a Pull Request detailing your changes and improvements.

## License
This project is licensed under the MIT License.

## Questions or Issues
If you encounter any issues or have suggestions, please open an issue or contact me.

***Always review and test security implications, especially before deploying on mainnet. The current iteration of this has not been audited, use at your own risk*** 
