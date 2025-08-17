# 🛍️ Decentralized eBay Smart Contract

A trustless peer-to-peer marketplace built on Stacks blockchain that enables secure transactions between buyers and sellers without intermediaries.

## 🌟 Features

- Create product listings with title, description and price
- Secure escrow system for payments
- Buyer confirmation mechanism
- Seller reputation tracking
- Dispute resolution timeouts
- Refund capabilities

## 📝 Contract Functions

### For Sellers

- `create-listing`: Create a new product listing
- `refund-buyer`: Issue refund to buyer

### For Buyers

- `purchase-listing`: Purchase an item (locks payment in escrow)
- `confirm-delivery`: Confirm delivery to release payment

### Read-Only Functions

- `get-listing`: Get details of a specific listing
- `get-seller-reputation`: View seller's reputation stats

## 🔧 Usage Example

```clarity
;; Create a listing
(contract-call? .decentralized-ebay create-listing "iPhone 13" "New sealed iPhone 13 128GB" u1000000000)

;; Purchase a listing
(contract-call? .decentralized-ebay purchase-listing u0)

;; Confirm delivery
(contract-call? .decentralized-ebay confirm-delivery u0)
```

## ⚠️ Important Notes

- All payments are made in STX
- Escrow period: 7 days
- Dispute window: 24 hours
- Prices should be in micro-STX (1 STX = 1,000,000 micro-STX)

## 🔒 Security

The contract implements secure escrow mechanics and timeout-based dispute resolution to protect both buyers and sellers.
```