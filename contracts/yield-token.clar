;; Title: Obelisk Yield Token (YT-STX)
;; Description: SIP-010 compliant Yield Token entitling holders to stream accrued PoX stacking rewards

(impl-trait .sip-010-trait.sip-010-trait)

(define-fungible-token yield-token)

;; Constants & Errors
(define-constant ERR_NOT_AUTHORIZED (err u300))
(define-constant ERR_ZERO_AMOUNT (err u301))

(define-constant TOKEN_NAME "Obelisk Yield Token")
(define-constant TOKEN_SYMBOL "YT-STX")
(define-constant TOKEN_DECIMALS u6)
(define-constant TOKEN_URI (some u"https://obelisk.finance/metadata/yt-stx.json"))

(define-data-var contract-owner principal tx-sender)
(define-data-var authorized-vault principal tx-sender)

;; Administrative Settings
(define-public (set-authorized-vault (new-vault principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (var-set authorized-vault new-vault)
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

;; Minting (strictly authorized vault or owner)
(define-public (mint
    (recipient principal)
    (amount uint)
  )
  (begin
    (asserts!
      (or
        (is-eq contract-caller (var-get authorized-vault))
        (is-eq tx-sender (var-get contract-owner))
      )
      ERR_NOT_AUTHORIZED
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (ft-mint? yield-token amount recipient)
  )
)

;; Burning (strictly authorized vault or owner)
(define-public (burn
    (owner principal)
    (amount uint)
  )
  (begin
    (asserts!
      (or
        (is-eq contract-caller (var-get authorized-vault))
        (is-eq tx-sender (var-get contract-owner))
      )
      ERR_NOT_AUTHORIZED
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (ft-burn? yield-token amount owner)
  )
)

;; SIP-010 Transfer
(define-public (transfer
    (amount uint)
    (sender principal)
    (recipient principal)
    (memo (optional (buff 34)))
  )
  (begin
    (asserts! (or (is-eq tx-sender sender) (is-eq contract-caller sender))
      ERR_NOT_AUTHORIZED
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (ft-transfer? yield-token amount sender recipient))
    (match memo
      to-print (print to-print)
      0x
    )
    (ok true)
  )
)

;; SIP-010 Read-Only Getters
(define-read-only (get-name)
  (ok TOKEN_NAME)
)

(define-read-only (get-symbol)
  (ok TOKEN_SYMBOL)
)

(define-read-only (get-decimals)
  (ok TOKEN_DECIMALS)
)

(define-read-only (get-balance (account principal))
  (ok (ft-get-balance yield-token account))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply yield-token))
)

(define-read-only (get-token-uri)
  (ok TOKEN_URI)
)

(define-read-only (get-authorized-vault)
  (ok (var-get authorized-vault))
)
