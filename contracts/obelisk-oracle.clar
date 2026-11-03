;; Title: Obelisk Yield & Price Feed Oracle
;; Description: Multi-reporter decentralized oracle providing STX/USD, BTC/USD prices and PoX Stacking APY rates

(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_ORACLE_STALE (err u101))
(define-constant ERR_INVALID_PRICE (err u102))
(define-constant ERR_CIRCUIT_BREAKER_TRIGGERED (err u103))
(define-constant ERR_ALREADY_REPORTER (err u104))
(define-constant ERR_REPORTER_NOT_FOUND (err u105))

(define-data-var contract-owner principal tx-sender)
(define-data-var max-staleness-blocks uint u288) ;; ~48 hours in Stacks blocks
(define-constant MAX_DEVIATION_BPS u3000) ;; 30% max swing between updates

;; Oracle State
(define-data-var stx-usd-price uint u2500000) ;; $2.50 (6 decimals)
(define-data-var btc-usd-price uint u95000000000) ;; $95,000 (6 decimals)
(define-data-var pox-apy-bps uint u850) ;; 8.50% annual yield in basis points
(define-data-var last-updated-block uint u0)
(define-data-var update-counter uint u0)

;; Authorized reporters registry
(define-map authorized-reporters
  principal
  bool
)
(define-map reporter-last-submission
  principal
  uint
)

;; Initialize deployer as first authorized reporter
(map-set authorized-reporters tx-sender true)

;; Administration
(define-public (add-reporter (reporter principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (is-none (map-get? authorized-reporters reporter))
      ERR_ALREADY_REPORTER
    )
    (map-set authorized-reporters reporter true)
    (ok true)
  )
)

(define-public (remove-reporter (reporter principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (is-some (map-get? authorized-reporters reporter))
      ERR_REPORTER_NOT_FOUND
    )
    (map-delete authorized-reporters reporter)
    (ok true)
  )
)

(define-public (set-max-staleness (new-staleness uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (> new-staleness u0) ERR_INVALID_PRICE)
    (var-set max-staleness-blocks new-staleness)
    (ok true)
  )
)

(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; Submit Oracle Data
(define-public (submit-oracle-data
    (new-stx-usd uint)
    (new-btc-usd uint)
    (new-pox-apy-bps uint)
  )
  (let (
      (current-stx (var-get stx-usd-price))
      (allowed-dev MAX_DEVIATION_BPS)
    )
    (asserts! (default-to false (map-get? authorized-reporters tx-sender))
      ERR_NOT_AUTHORIZED
    )
    (asserts! (> new-stx-usd u0) ERR_INVALID_PRICE)
    (asserts! (> new-btc-usd u0) ERR_INVALID_PRICE)
    (asserts! (> new-pox-apy-bps u0) ERR_INVALID_PRICE)

    ;; Circuit breaker validation if previous update exists
    (if (> (var-get last-updated-block) u0)
      (let (
          (diff (if (> new-stx-usd current-stx)
            (- new-stx-usd current-stx)
            (- current-stx new-stx-usd)
          ))
          (rel-dev (/ (* diff u10000) current-stx))
        )
        (asserts! (<= rel-dev allowed-dev) ERR_CIRCUIT_BREAKER_TRIGGERED)
      )
      true
    )

    (var-set stx-usd-price new-stx-usd)
    (var-set btc-usd-price new-btc-usd)
    (var-set pox-apy-bps new-pox-apy-bps)
    (var-set last-updated-block block-height)
    (var-set update-counter (+ (var-get update-counter) u1))
    (map-set reporter-last-submission tx-sender block-height)

    (ok (var-get update-counter))
  )
)

;; Read-Only Queries
(define-read-only (is-stale)
  (let ((last (var-get last-updated-block)))
    (if (is-eq last u0)
      false
      (> (- block-height last) (var-get max-staleness-blocks))
    )
  )
)

(define-read-only (get-stx-usd)
  (begin
    (asserts! (not (is-stale)) ERR_ORACLE_STALE)
    (ok (var-get stx-usd-price))
  )
)

(define-read-only (get-btc-usd)
  (begin
    (asserts! (not (is-stale)) ERR_ORACLE_STALE)
    (ok (var-get btc-usd-price))
  )
)

(define-read-only (get-pox-apy-bps)
  (begin
    (asserts! (not (is-stale)) ERR_ORACLE_STALE)
    (ok (var-get pox-apy-bps))
  )
)

(define-read-only (get-oracle-summary)
  (ok {
    stx-usd: (var-get stx-usd-price),
    btc-usd: (var-get btc-usd-price),
    pox-apy-bps: (var-get pox-apy-bps),
    last-updated: (var-get last-updated-block),
    update-count: (var-get update-counter),
    stale: (is-stale),
  })
)

(define-read-only (is-reporter-authorized (reporter principal))
  (default-to false (map-get? authorized-reporters reporter))
)

(define-read-only (get-reporter-last-submission (reporter principal))
  (map-get? reporter-last-submission reporter)
)
