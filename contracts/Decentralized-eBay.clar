(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-LISTING-EXPIRED (err u101))
(define-constant ERR-WRONG-PRICE (err u102))
(define-constant ERR-ALREADY-PURCHASED (err u103))
(define-constant ERR-NOT-FOUND (err u104))
(define-constant ERR-ALREADY-EXISTS (err u105))
(define-constant ERR-DISPUTE-WINDOW-CLOSED (err u106))

(define-data-var next-listing-id uint u0)
(define-data-var dispute-period uint u144) ;; ~1 day in blocks
(define-data-var escrow-period uint u1008) ;; ~7 days in blocks

(define-map Listings 
    { listing-id: uint }
    {
        seller: principal,
        title: (string-ascii 100),
        description: (string-ascii 500),
        price: uint,
        created-at: uint,
        status: (string-ascii 20),
        buyer: (optional principal)
    }
)

(define-map Escrows
    { listing-id: uint }
    {
        amount: uint,
        buyer: principal,
        release-height: uint,
        dispute-height: uint
    }
)

(define-map SellerReputations
    { seller: principal }
    {
        successful-sales: uint,
        disputes: uint,
        rating-sum: uint,
        rating-count: uint
    }
)

(define-public (create-listing (title (string-ascii 100)) (description (string-ascii 500)) (price uint))
    (let
        ((listing-id (var-get next-listing-id)))
        (asserts! (map-insert Listings
            { listing-id: listing-id }
            {
                seller: tx-sender,
                title: title,
                description: description,
                price: price,
                created-at: burn-block-height,
                status: "active",
                buyer: none
            }
        ) ERR-ALREADY-EXISTS)
        (var-set next-listing-id (+ listing-id u1))
        (ok listing-id)
    )
)

(define-public (purchase-listing (listing-id uint))
    (let
        ((listing (unwrap! (map-get? Listings {listing-id: listing-id}) ERR-NOT-FOUND))
         (current-height burn-block-height))
        
        (asserts! (is-eq (get status listing) "active") ERR-ALREADY-PURCHASED)
        (try! (stx-transfer? (get price listing) tx-sender (as-contract tx-sender)))
        
        (map-set Listings
            { listing-id: listing-id }
            (merge listing {
                status: "pending",
                buyer: (some tx-sender)
            })
        )
        
        (map-insert Escrows
            { listing-id: listing-id }
            {
                amount: (get price listing),
                buyer: tx-sender,
                release-height: (+ current-height (var-get escrow-period)),
                dispute-height: (+ current-height (var-get dispute-period))
            }
        )
        (ok true)
    )
)

(define-public (confirm-delivery (listing-id uint))
    (let
        ((listing (unwrap! (map-get? Listings {listing-id: listing-id}) ERR-NOT-FOUND))
         (escrow (unwrap! (map-get? Escrows {listing-id: listing-id}) ERR-NOT-FOUND)))
        
        (asserts! (is-eq (some tx-sender) (get buyer listing)) ERR-NOT-AUTHORIZED)
        
        (try! (as-contract (stx-transfer? (get amount escrow) tx-sender (get seller listing))))
        (map-set Listings {listing-id: listing-id} (merge listing {status: "completed"}))
        (map-delete Escrows {listing-id: listing-id})
        
        (update-seller-reputation (get seller listing) true none)
        (ok true)
    )
)


(define-public (refund-buyer (listing-id uint))
    (let
        ((listing (unwrap! (map-get? Listings {listing-id: listing-id}) ERR-NOT-FOUND))
         (escrow (unwrap! (map-get? Escrows {listing-id: listing-id}) ERR-NOT-FOUND)))
        
        (asserts! (is-eq tx-sender (get seller listing)) ERR-NOT-AUTHORIZED)
        
        (try! (as-contract (stx-transfer? (get amount escrow) tx-sender (unwrap! (get buyer listing) ERR-NOT-FOUND))))
        (map-set Listings {listing-id: listing-id} (merge listing {status: "refunded"}))
        (map-delete Escrows {listing-id: listing-id})
        (ok true)
    )
)

(define-private (update-seller-reputation (seller principal) (successful bool) (rating (optional uint)))
    (let
        ((current-rep (default-to
            {
                successful-sales: u0,
                disputes: u0,
                rating-sum: u0,
                rating-count: u0
            }
            (map-get? SellerReputations {seller: seller}))))
        
        (map-set SellerReputations
            {seller: seller}
            (merge current-rep
                {
                    successful-sales: (if successful (+ (get successful-sales current-rep) u1) (get successful-sales current-rep)),
                    disputes: (if successful (get disputes current-rep) (+ (get disputes current-rep) u1))
                }
            )
        )
    )
)

(define-read-only (get-listing (listing-id uint))
    (map-get? Listings {listing-id: listing-id})
)

(define-read-only (get-seller-reputation (seller principal))
    (map-get? SellerReputations {seller: seller})
)
