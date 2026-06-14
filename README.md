# 🧩 Bluxe NFT Marketplace

A production-grade, modular NFT marketplace smart contract system built in Solidity using Foundry.
It supports listings, direct purchases, offers system, escrow-based settlement, royalty distribution (ERC-2981), and platform fee management.

---

## 🚀 Features

### 🖼 NFT Marketplace Core

* NFT Listing & Delisting
* Direct Buy functionality
* Escrow-based secure transfers
* Listing state management (active/inactive)

### 💰 Offer System

* Make offers using ETH
* Cancel offers anytime
* Top offer tracking per listing
* Offer refund mechanism

### 🏦 Payments System

* Automatic royalty distribution (ERC-2981)
* Platform fee system (configurable max 10%)
* Seller payout after fee deductions
* Pending withdrawal balance system

### 🔐 Security & Architecture

* Modular contract separation:

  * Marketplace (logic layer)
  * Storage (state layer)
  * Offer Manager (offer logic layer)
* Access control via owner/authorized roles
* Cross-contract secure communication design

## 🧪 Testing

- Fully tested using Foundry (Forge)
- Unit + integration tests
- Fuzz testing via Foundry
- Property-based testing using **Echidna (Docker)**

### 🔐 Invariant Testing (Echidna)
The system is verified against multiple invariants:

- ETH accounting consistency invariant (no ETH loss)
- Listing integrity invariant (valid price, seller, state)
- Auction correctness invariant (no bids after expiry)
- No stuck NFT invariant (NFT always recoverable)
- Bid refund safety invariant (all refunds preserved)
- Economic safety invariant (total payouts ≤ total ETH in)
- Malicious NFT behavior resistance (EvilERC2981 simulation)
- Storage integrity between modules
- Adversarial / evil test simulation

  ### 🧪 Adversarial Testing
- Fake NFT contracts with malicious royalty logic
- Edge-case offer cancellations
- Zero-value / invalid offers
- Unauthorized state manipulation attempts
- Reentrancy-style payout simulation checks

---

## 🏗 Architecture

```
User
 ↓
BluxeMarketplace (Logic Layer)
 ↓
BluxeStorage (State Layer)
 ↓
BluxeOfferManager (Offer Logic)
 ↓
BluxeToken (ERC721 NFT)
```

---

## 📦 Tech Stack

* Solidity ^0.8.28
* Foundry (Forge + Anvil)
* ERC721 Standard
* ERC2981 Royalty Standard

---

## 📁 Project Structure

```
bluxe-nft-marketplace/
│
├── src/
│   ├── BluxeBidManager.sol
│   ├── BluxeMarketplace.sol
│   ├── BluxeOfferManager.sol
│   ├── BluxeStorage.sol
│   ├── BluxeToken.sol
│   ├── EvilERC721.sol
│   ├── EvilERC2981.sol
│   └── MockWeth.sol
│
├── test/
│   ├── BidHandler.s.sol
│   ├── BluxeInvariantsTest.s.sol
│   ├── BluxeTest.s.sol
│   ├── MaliciousContract.sol
│   ├── MarketplaceHandler.s.sol
│   ├── Offerhandler.s.sol
│   ├── bluxeMarketplace.t.sol
│   └── evilTest.s.sol
│
├── foundry.toml
└── README.md
```

---

## ⚙️ Installation & Setup

```bash
git clone https://github.com/your-username/bluxe-nft-marketplace.git
cd bluxe-nft-marketplace
forge install
forge build
```

---

## 🧪 Run Tests

```bash
forge test -vvvv
```

---

## 📊 Key Functionalities

### 📌 Create Listing

NFT owner can list their NFT for sale.

### 📌 Make Offer

Users can place ETH offers on listed NFTs.

### 📌 Cancel Offer

Offer maker can cancel and get refund.

### 📌 Accept Offer

Seller accepts offer → NFT transfer + payout execution.

### 📌 Platform Fee Update

Owner can update marketplace fee (max 10%).

---

## 💸 Fee System

* Platform Fee: configurable (max 1000 bps = 10%)
* ERC-2981 Royalties supported
* Seller receives remaining balance after deductions

---

## 🔐 Access Control

| Function          | Access                     |
| ----------------- | ---------------------------|
| updatePlatformFee | Owner only & Marketplace   |
| createListing     | NFT owner                  |
| makeOffer         | Public                     |
| cancelOffer       | Offer creator              |

---

## 🧠 Learnings / Highlights

This project demonstrates:

* Real-world DeFi marketplace architecture
* Cross-contract interaction patterns
* State separation (Storage vs Logic)
* Offer book system design
* Advanced Foundry testing strategies
* Event-driven accounting system

---

## ⚠️ Notes

* Designed for learning + production-style architecture practice
* Modular design allows future L2 scaling
* Optimized for clarity and correctness over micro gas optimizations

---

## 👨‍💻 Author

Built by **0xSmartCoder**
Focused on Solidity, DeFi systems, and smart contract architecture.

---

## ⭐ Support

If you like this project, consider giving it a ⭐ on GitHub.
