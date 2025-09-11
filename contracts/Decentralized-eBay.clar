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

(define-constant ERR-AUCTION-ENDED (err u107))
(define-constant ERR-BID-TOO-LOW (err u108))
(define-constant ERR-AUCTION-ACTIVE (err u109))
(define-constant ERR-NOT-WINNER (err u110))
(define-constant ERR-ALREADY-FAVORITED (err u111))
(define-constant ERR-NOT-FAVORITED (err u112))

(define-map Auctions
    { listing-id: uint }
    {
        starting-price: uint,
        current-bid: uint,
        highest-bidder: (optional principal),
        end-height: uint,
        bid-count: uint
    }
)

(define-map Bids
    { listing-id: uint, bidder: principal }
    {
        amount: uint,
        bid-height: uint
    }
)

(define-public (create-auction-listing (title (string-ascii 100)) (description (string-ascii 500)) (starting-price uint) (duration uint))
    (let
        ((listing-id (var-get next-listing-id))
         (end-height (+ burn-block-height duration)))
        (asserts! (map-insert Listings
            { listing-id: listing-id }
            {
                seller: tx-sender,
                title: title,
                description: description,
                price: starting-price,
                created-at: burn-block-height,
                status: "auction",
                buyer: none
            }
        ) ERR-ALREADY-EXISTS)
        
        (map-insert Auctions
            { listing-id: listing-id }
            {
                starting-price: starting-price,
                current-bid: starting-price,
                highest-bidder: none,
                end-height: end-height,
                bid-count: u0
            }
        )
        
        (var-set next-listing-id (+ listing-id u1))
        (ok listing-id)
    )
)

(define-public (place-bid (listing-id uint) (bid-amount uint))
    (let
        ((listing (unwrap! (map-get? Listings {listing-id: listing-id}) ERR-NOT-FOUND))
         (auction (unwrap! (map-get? Auctions {listing-id: listing-id}) ERR-NOT-FOUND))
         (current-height burn-block-height))
        
        (asserts! (is-eq (get status listing) "auction") ERR-NOT-FOUND)
        (asserts! (< current-height (get end-height auction)) ERR-AUCTION-ENDED)
        (asserts! (> bid-amount (get current-bid auction)) ERR-BID-TOO-LOW)
        (asserts! (not (is-eq tx-sender (get seller listing))) ERR-NOT-AUTHORIZED)
        
        (let ((previous-bidder (get highest-bidder auction)))
            (if (is-some previous-bidder)
                (try! (as-contract (stx-transfer? (get current-bid auction) tx-sender (unwrap-panic previous-bidder))))
                true
            )
        )
        
        (try! (stx-transfer? bid-amount tx-sender (as-contract tx-sender)))
        
        (map-set Auctions
            { listing-id: listing-id }
            (merge auction {
                current-bid: bid-amount,
                highest-bidder: (some tx-sender),
                bid-count: (+ (get bid-count auction) u1)
            })
        )
        
        (map-set Bids
            { listing-id: listing-id, bidder: tx-sender }
            {
                amount: bid-amount,
                bid-height: current-height
            }
        )
        
        (ok true)
    )
)

(define-public (finalize-auction (listing-id uint))
    (let
        ((listing (unwrap! (map-get? Listings {listing-id: listing-id}) ERR-NOT-FOUND))
         (auction (unwrap! (map-get? Auctions {listing-id: listing-id}) ERR-NOT-FOUND))
         (current-height burn-block-height))
        
        (asserts! (is-eq (get status listing) "auction") ERR-NOT-FOUND)
        (asserts! (>= current-height (get end-height auction)) ERR-AUCTION-ACTIVE)
        
        (if (is-some (get highest-bidder auction))
            (begin
                (map-set Listings
                    { listing-id: listing-id }
                    (merge listing {
                        status: "pending",
                        buyer: (get highest-bidder auction),
                        price: (get current-bid auction)
                    })
                )
                
                (map-insert Escrows
                    { listing-id: listing-id }
                    {
                        amount: (get current-bid auction),
                        buyer: (unwrap-panic (get highest-bidder auction)),
                        release-height: (+ current-height (var-get escrow-period)),
                        dispute-height: (+ current-height (var-get dispute-period))
                    }
                )
            )
            (map-set Listings
                { listing-id: listing-id }
                (merge listing { status: "expired" })
            )
        )
        
        (ok true)
    )
)

(define-read-only (get-auction (listing-id uint))
    (map-get? Auctions {listing-id: listing-id})
)

(define-read-only (get-bid (listing-id uint) (bidder principal))
    (map-get? Bids {listing-id: listing-id, bidder: bidder})
)

(define-constant ERR-INVALID-CATEGORY (err u113))
(define-constant ERR-INVALID-FILTER (err u114))

(define-data-var category-count uint u8)

(define-map Categories
    { category-id: uint }
    {
        name: (string-ascii 50),
        description: (string-ascii 200),
        active: bool
    }
)

(define-map ListingCategories
    { listing-id: uint }
    {
        category-id: uint,
        subcategory: (string-ascii 50),
        tags: (list 5 (string-ascii 20))
    }
)

(define-map CategoryListings
    { category-id: uint, listing-id: uint }
    {
        created-at: uint,
        price: uint,
        status: (string-ascii 20)
    }
)

(define-private (initialize-categories)
    (begin
        (map-set Categories { category-id: u1 } { name: "Electronics", description: "Electronic devices and gadgets", active: true })
        (map-set Categories { category-id: u2 } { name: "Clothing", description: "Apparel and accessories", active: true })
        (map-set Categories { category-id: u3 } { name: "Books", description: "Books and educational materials", active: true })
        (map-set Categories { category-id: u4 } { name: "Home", description: "Home and garden items", active: true })
        (map-set Categories { category-id: u5 } { name: "Sports", description: "Sports and outdoor equipment", active: true })
        (map-set Categories { category-id: u6 } { name: "Automotive", description: "Car parts and accessories", active: true })
        (map-set Categories { category-id: u7 } { name: "Collectibles", description: "Rare and collectible items", active: true })
        (map-set Categories { category-id: u8 } { name: "Other", description: "Miscellaneous items", active: true })
    )
)

(define-public (create-categorized-listing (title (string-ascii 100)) (description (string-ascii 500)) (price uint) (category-id uint) (subcategory (string-ascii 50)) (tags (list 5 (string-ascii 20))))
    (let
        ((listing-id (var-get next-listing-id))
         (category (unwrap! (map-get? Categories {category-id: category-id}) ERR-INVALID-CATEGORY)))
        
        (asserts! (get active category) ERR-INVALID-CATEGORY)
        (asserts! (<= category-id (var-get category-count)) ERR-INVALID-CATEGORY)
        
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
        
        (map-insert ListingCategories
            { listing-id: listing-id }
            {
                category-id: category-id,
                subcategory: subcategory,
                tags: tags
            }
        )
        
        (map-insert CategoryListings
            { category-id: category-id, listing-id: listing-id }
            {
                created-at: burn-block-height,
                price: price,
                status: "active"
            }
        )
        
        (var-set next-listing-id (+ listing-id u1))
        (ok listing-id)
    )
)

(define-public (update-listing-category (listing-id uint) (category-id uint) (subcategory (string-ascii 50)) (tags (list 5 (string-ascii 20))))
    (let
        ((listing (unwrap! (map-get? Listings {listing-id: listing-id}) ERR-NOT-FOUND))
         (category (unwrap! (map-get? Categories {category-id: category-id}) ERR-INVALID-CATEGORY))
         (old-category (map-get? ListingCategories {listing-id: listing-id})))
        
        (asserts! (is-eq tx-sender (get seller listing)) ERR-NOT-AUTHORIZED)
        (asserts! (get active category) ERR-INVALID-CATEGORY)
        
        (if (is-some old-category)
            (map-delete CategoryListings 
                { category-id: (get category-id (unwrap-panic old-category)), listing-id: listing-id })
            true
        )
        
        (map-set ListingCategories
            { listing-id: listing-id }
            {
                category-id: category-id,
                subcategory: subcategory,
                tags: tags
            }
        )
        
        (map-set CategoryListings
            { category-id: category-id, listing-id: listing-id }
            {
                created-at: (get created-at listing),
                price: (get price listing),
                status: (get status listing)
            }
        )
        
        (ok true)
    )
)

(define-read-only (get-category (category-id uint))
    (map-get? Categories {category-id: category-id})
)

(define-read-only (get-listing-category (listing-id uint))
    (map-get? ListingCategories {listing-id: listing-id})
)

(define-read-only (get-category-listing (category-id uint) (listing-id uint))
    (map-get? CategoryListings {category-id: category-id, listing-id: listing-id})
)

(define-read-only (get-all-categories)
    (list
        (map-get? Categories {category-id: u1})
        (map-get? Categories {category-id: u2})
        (map-get? Categories {category-id: u3})
        (map-get? Categories {category-id: u4})
        (map-get? Categories {category-id: u5})
        (map-get? Categories {category-id: u6})
        (map-get? Categories {category-id: u7})
        (map-get? Categories {category-id: u8})
    )
)

(define-map UserFavorites
    { user: principal, listing-id: uint }
    {
        added-at: uint,
        category-id: (optional uint)
    }
)

(define-map UserFavoriteCounts
    { user: principal }
    {
        total-favorites: uint
    }
)

(define-public (add-to-favorites (listing-id uint))
    (let
        ((listing (unwrap! (map-get? Listings {listing-id: listing-id}) ERR-NOT-FOUND))
         (favorite-key {user: tx-sender, listing-id: listing-id})
         (listing-category (map-get? ListingCategories {listing-id: listing-id}))
         (user-count (default-to {total-favorites: u0} (map-get? UserFavoriteCounts {user: tx-sender}))))
        
        (asserts! (is-none (map-get? UserFavorites favorite-key)) ERR-ALREADY-FAVORITED)
        
        (map-insert UserFavorites
            favorite-key
            {
                added-at: burn-block-height,
                category-id: (if (is-some listing-category) 
                    (some (get category-id (unwrap-panic listing-category))) 
                    none)
            }
        )
        
        (map-set UserFavoriteCounts
            {user: tx-sender}
            {total-favorites: (+ (get total-favorites user-count) u1)}
        )
        
        (ok true)
    )
)

(define-public (remove-from-favorites (listing-id uint))
    (let
        ((favorite-key {user: tx-sender, listing-id: listing-id})
         (favorite (unwrap! (map-get? UserFavorites favorite-key) ERR-NOT-FAVORITED))
         (user-count (default-to {total-favorites: u0} (map-get? UserFavoriteCounts {user: tx-sender}))))
        
        (map-delete UserFavorites favorite-key)
        
        (map-set UserFavoriteCounts
            {user: tx-sender}
            {total-favorites: (if (> (get total-favorites user-count) u0) 
                (- (get total-favorites user-count) u1) 
                u0)}
        )
        
        (ok true)
    )
)

(define-read-only (is-favorited (user principal) (listing-id uint))
    (is-some (map-get? UserFavorites {user: user, listing-id: listing-id}))
)

(define-read-only (get-user-favorite-count (user principal))
    (get total-favorites (default-to {total-favorites: u0} (map-get? UserFavoriteCounts {user: user})))
)

(define-read-only (get-favorite-details (user principal) (listing-id uint))
    (map-get? UserFavorites {user: user, listing-id: listing-id})
)

(define-constant ERR-BULK-LIMIT-EXCEEDED (err u115))
(define-constant ERR-BULK-OPERATION-FAILED (err u116))
(define-constant MAX-BULK-OPERATIONS u10)

(define-data-var bulk-operation-id uint u0)

(define-map BulkOperationResults
    { operation-id: uint }
    {
        initiator: principal,
        total-operations: uint,
        successful-operations: uint,
        failed-operations: uint,
        created-at: uint
    }
)

(define-map BulkOperationDetails
    { operation-id: uint, index: uint }
    {
        operation-type: (string-ascii 20),
        target-id: uint,
        success: bool,
        error-code: (optional uint)
    }
)

(define-public (bulk-create-listings (listings-data (list 10 {title: (string-ascii 100), description: (string-ascii 500), price: uint})))
    (let
        ((operation-id (var-get bulk-operation-id))
         (total-count (len listings-data))
         (results (fold process-bulk-listing listings-data {successful: u0, failed: u0, index: u0, operation-id: operation-id})))
        
        (asserts! (<= total-count MAX-BULK-OPERATIONS) ERR-BULK-LIMIT-EXCEEDED)
        
        (map-set BulkOperationResults
            {operation-id: operation-id}
            {
                initiator: tx-sender,
                total-operations: total-count,
                successful-operations: (get successful results),
                failed-operations: (get failed results),
                created-at: burn-block-height
            }
        )
        
        (var-set bulk-operation-id (+ operation-id u1))
        (ok {operation-id: operation-id, successful: (get successful results), failed: (get failed results)})
    )
)

(define-private (process-bulk-listing (listing-data {title: (string-ascii 100), description: (string-ascii 500), price: uint}) (acc {successful: uint, failed: uint, index: uint, operation-id: uint}))
    (let
        ((listing-id (var-get next-listing-id))
         (creation-result (map-insert Listings
            {listing-id: listing-id}
            {
                seller: tx-sender,
                title: (get title listing-data),
                description: (get description listing-data),
                price: (get price listing-data),
                created-at: burn-block-height,
                status: "active",
                buyer: none
            }
         )))
        
        (if creation-result
            (begin
                (var-set next-listing-id (+ listing-id u1))
                (map-set BulkOperationDetails
                    {operation-id: (get operation-id acc), index: (get index acc)}
                    {
                        operation-type: "create-listing",
                        target-id: listing-id,
                        success: true,
                        error-code: none
                    }
                )
                {
                    successful: (+ (get successful acc) u1),
                    failed: (get failed acc),
                    index: (+ (get index acc) u1),
                    operation-id: (get operation-id acc)
                }
            )
            (begin
                (map-set BulkOperationDetails
                    {operation-id: (get operation-id acc), index: (get index acc)}
                    {
                        operation-type: "create-listing",
                        target-id: u0,
                        success: false,
                        error-code: (some u105)
                    }
                )
                {
                    successful: (get successful acc),
                    failed: (+ (get failed acc) u1),
                    index: (+ (get index acc) u1),
                    operation-id: (get operation-id acc)
                }
            )
        )
    )
)

(define-public (bulk-add-favorites (listing-ids (list 10 uint)))
    (let
        ((operation-id (var-get bulk-operation-id))
         (total-count (len listing-ids))
         (results (fold process-bulk-favorite listing-ids {successful: u0, failed: u0, index: u0, operation-id: operation-id})))
        
        (asserts! (<= total-count MAX-BULK-OPERATIONS) ERR-BULK-LIMIT-EXCEEDED)
        
        (map-set BulkOperationResults
            {operation-id: operation-id}
            {
                initiator: tx-sender,
                total-operations: total-count,
                successful-operations: (get successful results),
                failed-operations: (get failed results),
                created-at: burn-block-height
            }
        )
        
        (var-set bulk-operation-id (+ operation-id u1))
        (ok {operation-id: operation-id, successful: (get successful results), failed: (get failed results)})
    )
)

(define-private (process-bulk-favorite (listing-id uint) (acc {successful: uint, failed: uint, index: uint, operation-id: uint}))
    (let
        ((favorite-key {user: tx-sender, listing-id: listing-id})
         (listing-exists (is-some (map-get? Listings {listing-id: listing-id})))
         (not-favorited (is-none (map-get? UserFavorites favorite-key)))
         (listing-category (map-get? ListingCategories {listing-id: listing-id}))
         (user-count (default-to {total-favorites: u0} (map-get? UserFavoriteCounts {user: tx-sender}))))
        
        (if (and listing-exists not-favorited)
            (begin
                (map-insert UserFavorites
                    favorite-key
                    {
                        added-at: burn-block-height,
                        category-id: (if (is-some listing-category) 
                            (some (get category-id (unwrap-panic listing-category))) 
                            none)
                    }
                )
                (map-set UserFavoriteCounts
                    {user: tx-sender}
                    {total-favorites: (+ (get total-favorites user-count) u1)}
                )
                (map-set BulkOperationDetails
                    {operation-id: (get operation-id acc), index: (get index acc)}
                    {
                        operation-type: "add-favorite",
                        target-id: listing-id,
                        success: true,
                        error-code: none
                    }
                )
                {
                    successful: (+ (get successful acc) u1),
                    failed: (get failed acc),
                    index: (+ (get index acc) u1),
                    operation-id: (get operation-id acc)
                }
            )
            (begin
                (map-set BulkOperationDetails
                    {operation-id: (get operation-id acc), index: (get index acc)}
                    {
                        operation-type: "add-favorite",
                        target-id: listing-id,
                        success: false,
                        error-code: (some (if listing-exists u111 u104))
                    }
                )
                {
                    successful: (get successful acc),
                    failed: (+ (get failed acc) u1),
                    index: (+ (get index acc) u1),
                    operation-id: (get operation-id acc)
                }
            )
        )
    )
)

(define-public (bulk-update-listing-prices (updates (list 10 {listing-id: uint, new-price: uint})))
    (let
        ((operation-id (var-get bulk-operation-id))
         (total-count (len updates))
         (results (fold process-bulk-price-update updates {successful: u0, failed: u0, index: u0, operation-id: operation-id})))
        
        (asserts! (<= total-count MAX-BULK-OPERATIONS) ERR-BULK-LIMIT-EXCEEDED)
        
        (map-set BulkOperationResults
            {operation-id: operation-id}
            {
                initiator: tx-sender,
                total-operations: total-count,
                successful-operations: (get successful results),
                failed-operations: (get failed results),
                created-at: burn-block-height
            }
        )
        
        (var-set bulk-operation-id (+ operation-id u1))
        (ok {operation-id: operation-id, successful: (get successful results), failed: (get failed results)})
    )
)

(define-private (process-bulk-price-update (update {listing-id: uint, new-price: uint}) (acc {successful: uint, failed: uint, index: uint, operation-id: uint}))
    (let
        ((listing-id (get listing-id update))
         (new-price (get new-price update))
         (listing (map-get? Listings {listing-id: listing-id})))
        
        (if (and (is-some listing) (is-eq tx-sender (get seller (unwrap-panic listing))) (is-eq (get status (unwrap-panic listing)) "active"))
            (begin
                (map-set Listings
                    {listing-id: listing-id}
                    (merge (unwrap-panic listing) {price: new-price})
                )
                (let ((listing-category (map-get? ListingCategories {listing-id: listing-id})))
                    (if (is-some listing-category)
                        (map-set CategoryListings
                            {category-id: (get category-id (unwrap-panic listing-category)), listing-id: listing-id}
                            {
                                created-at: (get created-at (unwrap-panic listing)),
                                price: new-price,
                                status: (get status (unwrap-panic listing))
                            }
                        )
                        true
                    )
                )
                (map-set BulkOperationDetails
                    {operation-id: (get operation-id acc), index: (get index acc)}
                    {
                        operation-type: "update-price",
                        target-id: listing-id,
                        success: true,
                        error-code: none
                    }
                )
                {
                    successful: (+ (get successful acc) u1),
                    failed: (get failed acc),
                    index: (+ (get index acc) u1),
                    operation-id: (get operation-id acc)
                }
            )
            (begin
                (map-set BulkOperationDetails
                    {operation-id: (get operation-id acc), index: (get index acc)}
                    {
                        operation-type: "update-price",
                        target-id: listing-id,
                        success: false,
                        error-code: (some (if (is-some listing) u100 u104))
                    }
                )
                {
                    successful: (get successful acc),
                    failed: (+ (get failed acc) u1),
                    index: (+ (get index acc) u1),
                    operation-id: (get operation-id acc)
                }
            )
        )
    )
)

(define-read-only (get-bulk-operation-results (operation-id uint))
    (map-get? BulkOperationResults {operation-id: operation-id})
)

(define-read-only (get-bulk-operation-detail (operation-id uint) (index uint))
    (map-get? BulkOperationDetails {operation-id: operation-id, index: index})
)

(define-read-only (get-next-bulk-operation-id)
    (var-get bulk-operation-id)
)
