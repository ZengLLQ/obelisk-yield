;; Title: YieldSpace Time-Dependent Invariant AMM
;; Description: Automated Market Maker enabling fixed-yield swaps between STX and Principal Tokens (PT-STX) with time-decayed discount pricing

;; Error Codes
(define-constant ERR_NOT_AUTHORIZED (err u600))
(define-constant ERR_POOL_EXISTS (err u601))
(define-constant ERR_POOL_NOT_FOUND (err u602))
(define-constant ERR_POOL_EXPIRED (err u603))
(define-constant ERR_ZERO_AMOUNT (err u604))
(define-constant ERR_INSUFFICIENT_LIQUIDITY (err u605))
(define-constant ERR_SLIPPAGE_EXCEEDED (err u606))
(define-constant ERR_INSUFFICIENT_BALANCE (err u607))
(define-constant ERR_INVALID_DURATION (err u608))

;; Math Constants
(define-constant BPS_DIVISOR u10000) ;; 10,000 basis points = 100%
(define-constant FEE_BPS u30) ;; 30 bps = 0.30% swap fee
(define-constant MAX_ANNUAL_DISCOUNT_BPS u1500) ;; 15.00% max annual implied yield rate

;; Protocol State
(define-data-var contract-owner principal tx-sender)

;; Pool Definition per Epoch
(define-map pools
  uint
  {
    reserve-stx: uint,
    reserve-pt: uint,
    total-lp-shares: uint,
    maturity-block: uint,
    epoch-duration: uint,
    total-volume-stx: uint,
  }
)

;; Liquidity Provider Shares
(define-map lp-balances
  {
    epoch-id: uint,
    provider: principal,
  }
  uint
)

;; Administration
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; --- Pool Creation ---

(define-public (initialize-pool
    (epoch-id uint)
    (maturity-block uint)
    (duration uint)
  )
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (is-none (map-get? pools epoch-id)) ERR_POOL_EXISTS)
    (asserts! (> maturity-block block-height) ERR_POOL_EXPIRED)
    (asserts! (> duration u0) ERR_INVALID_DURATION)

    (map-set pools epoch-id {
      reserve-stx: u0,
      reserve-pt: u0,
      total-lp-shares: u0,
      maturity-block: maturity-block,
      epoch-duration: duration,
      total-volume-stx: u0,
    })

    (ok true)
  )
)

;; --- Math & Pricing Helpers ---

;; Calculate time weight (in basis points) remaining until maturity
(define-read-only (get-time-weight-bps
    (maturity-block uint)
    (duration uint)
  )
  (if (>= block-height maturity-block)
    u0
    (let ((remaining (- maturity-block block-height)))
      (if (>= remaining duration)
        BPS_DIVISOR
        (/ (* remaining BPS_DIVISOR) duration)
      )
    )
  )
)

;; Calculate dynamic discount applied to PT (in basis points)
(define-read-only (get-pt-discount-bps
    (maturity-block uint)
    (duration uint)
  )
  (let ((time-weight (get-time-weight-bps maturity-block duration)))
    (/ (* time-weight MAX_ANNUAL_DISCOUNT_BPS) BPS_DIVISOR)
  )
)

;; Calculate PT output for a given STX input
(define-read-only (quote-stx-to-pt
    (epoch-id uint)
    (stx-in uint)
  )
  (match (map-get? pools epoch-id)
    pool (if (or (is-eq stx-in u0) (is-eq (get reserve-pt pool) u0))
      (ok u0)
      (let (
          (net-stx (/ (* stx-in (- BPS_DIVISOR FEE_BPS)) BPS_DIVISOR))
          (discount (get-pt-discount-bps (get maturity-block pool)
            (get epoch-duration pool)
          ))
          (pt-gross (/ (* net-stx (+ BPS_DIVISOR discount)) BPS_DIVISOR))
        )
        (ok pt-gross)
      )
    )
    ERR_POOL_NOT_FOUND
  )
)

;; Calculate STX output for a given PT input
(define-read-only (quote-pt-to-stx
    (epoch-id uint)
    (pt-in uint)
  )
  (match (map-get? pools epoch-id)
    pool (if (or (is-eq pt-in u0) (is-eq (get reserve-stx pool) u0))
      (ok u0)
      (let (
          (net-pt (/ (* pt-in (- BPS_DIVISOR FEE_BPS)) BPS_DIVISOR))
          (discount (get-pt-discount-bps (get maturity-block pool)
            (get epoch-duration pool)
          ))
          (stx-gross (/ (* net-pt BPS_DIVISOR) (+ BPS_DIVISOR discount)))
        )
        (ok stx-gross)
      )
    )
    ERR_POOL_NOT_FOUND
  )
)

;; --- Liquidity Management ---

(define-public (add-liquidity
    (epoch-id uint)
    (stx-amount uint)
    (pt-amount uint)
  )
  (let (
      (caller tx-sender)
      (amm-addr (as-contract tx-sender))
      (pool (unwrap! (map-get? pools epoch-id) ERR_POOL_NOT_FOUND))
      (res-stx (get reserve-stx pool))
      (res-pt (get reserve-pt pool))
      (total-shares (get total-lp-shares pool))
    )
    (asserts! (> stx-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (> pt-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (< block-height (get maturity-block pool)) ERR_POOL_EXPIRED)

    ;; Transfer STX and PT into AMM
    (try! (stx-transfer? stx-amount caller amm-addr))
    (try! (contract-call? .principal-token transfer pt-amount caller amm-addr none))

    ;; Compute minted shares
    (let (
        (minted-shares (if (is-eq total-shares u0)
          (/ (+ stx-amount pt-amount) u2)
          (let (
              (share-stx (/ (* stx-amount total-shares) res-stx))
              (share-pt (/ (* pt-amount total-shares) res-pt))
            )
            (if (< share-stx share-pt)
              share-stx
              share-pt
            )
          )
        ))
        (existing-user-shares (default-to u0
          (map-get? lp-balances {
            epoch-id: epoch-id,
            provider: caller,
          })
        ))
      )
      (asserts! (> minted-shares u0) ERR_ZERO_AMOUNT)

      ;; Update pool state
      (map-set pools epoch-id
        (merge pool {
          reserve-stx: (+ res-stx stx-amount),
          reserve-pt: (+ res-pt pt-amount),
          total-lp-shares: (+ total-shares minted-shares),
        })
      )

      ;; Update provider LP balance
      (map-set lp-balances {
        epoch-id: epoch-id,
        provider: caller,
      }
        (+ existing-user-shares minted-shares)
      )

      (ok minted-shares)
    )
  )
)

(define-public (remove-liquidity
    (epoch-id uint)
    (shares-to-burn uint)
  )
  (let (
      (caller tx-sender)
      (pool (unwrap! (map-get? pools epoch-id) ERR_POOL_NOT_FOUND))
      (total-shares (get total-lp-shares pool))
      (res-stx (get reserve-stx pool))
      (res-pt (get reserve-pt pool))
      (user-shares (default-to u0
        (map-get? lp-balances {
          epoch-id: epoch-id,
          provider: caller,
        })
      ))
    )
    (asserts! (> shares-to-burn u0) ERR_ZERO_AMOUNT)
    (asserts! (<= shares-to-burn user-shares) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> total-shares u0) ERR_INSUFFICIENT_LIQUIDITY)

    (let (
        (stx-out (/ (* shares-to-burn res-stx) total-shares))
        (pt-out (/ (* shares-to-burn res-pt) total-shares))
      )
      (asserts! (and (> stx-out u0) (> pt-out u0)) ERR_INSUFFICIENT_LIQUIDITY)

      ;; Return assets to provider
      (try! (as-contract (stx-transfer? stx-out tx-sender caller)))
      (try! (as-contract (contract-call? .principal-token transfer pt-out tx-sender caller none)))

      ;; Update state
      (map-set pools epoch-id
        (merge pool {
          reserve-stx: (- res-stx stx-out),
          reserve-pt: (- res-pt pt-out),
          total-lp-shares: (- total-shares shares-to-burn),
        })
      )

      (map-set lp-balances {
        epoch-id: epoch-id,
        provider: caller,
      }
        (- user-shares shares-to-burn)
      )

      (ok {
        stx-returned: stx-out,
        pt-returned: pt-out,
      })
    )
  )
)

;; --- Swaps ---

;; Swap STX for PT (buying discounted Principal Tokens for locked fixed yield)
(define-public (swap-stx-for-pt
    (epoch-id uint)
    (stx-in uint)
    (min-pt-out uint)
  )
  (let (
      (caller tx-sender)
      (amm-addr (as-contract tx-sender))
      (pool (unwrap! (map-get? pools epoch-id) ERR_POOL_NOT_FOUND))
      (res-stx (get reserve-stx pool))
      (res-pt (get reserve-pt pool))
      (pt-out (unwrap! (quote-stx-to-pt epoch-id stx-in) ERR_POOL_NOT_FOUND))
    )
    (asserts! (> stx-in u0) ERR_ZERO_AMOUNT)
    (asserts! (>= pt-out min-pt-out) ERR_SLIPPAGE_EXCEEDED)
    (asserts! (< pt-out res-pt) ERR_INSUFFICIENT_LIQUIDITY)
    (asserts! (< block-height (get maturity-block pool)) ERR_POOL_EXPIRED)

    ;; Transfer STX from caller to AMM
    (try! (stx-transfer? stx-in caller amm-addr))

    ;; Transfer PT from AMM to caller
    (try! (as-contract (contract-call? .principal-token transfer pt-out tx-sender caller none)))

    ;; Update reserves
    (map-set pools epoch-id
      (merge pool {
        reserve-stx: (+ res-stx stx-in),
        reserve-pt: (- res-pt pt-out),
        total-volume-stx: (+ (get total-volume-stx pool) stx-in),
      })
    )

    (ok pt-out)
  )
)

;; Swap PT for STX (selling Principal Tokens for immediate liquidity)
(define-public (swap-pt-for-stx
    (epoch-id uint)
    (pt-in uint)
    (min-stx-out uint)
  )
  (let (
      (caller tx-sender)
      (amm-addr (as-contract tx-sender))
      (pool (unwrap! (map-get? pools epoch-id) ERR_POOL_NOT_FOUND))
      (res-stx (get reserve-stx pool))
      (res-pt (get reserve-pt pool))
      (stx-out (unwrap! (quote-pt-to-stx epoch-id pt-in) ERR_POOL_NOT_FOUND))
    )
    (asserts! (> pt-in u0) ERR_ZERO_AMOUNT)
    (asserts! (>= stx-out min-stx-out) ERR_SLIPPAGE_EXCEEDED)
    (asserts! (< stx-out res-stx) ERR_INSUFFICIENT_LIQUIDITY)

    ;; Transfer PT from caller to AMM
    (try! (contract-call? .principal-token transfer pt-in caller amm-addr none))

    ;; Transfer STX from AMM to caller
    (try! (as-contract (stx-transfer? stx-out tx-sender caller)))

    ;; Update reserves
    (map-set pools epoch-id
      (merge pool {
        reserve-stx: (- res-stx stx-out),
        reserve-pt: (+ res-pt pt-in),
        total-volume-stx: (+ (get total-volume-stx pool) stx-out),
      })
    )

    (ok stx-out)
  )
)

;; --- Read-Only Getters ---

(define-read-only (get-pool (epoch-id uint))
  (map-get? pools epoch-id)
)

(define-read-only (get-lp-balance
    (epoch-id uint)
    (provider principal)
  )
  (default-to u0
    (map-get? lp-balances {
      epoch-id: epoch-id,
      provider: provider,
    })
  )
)
