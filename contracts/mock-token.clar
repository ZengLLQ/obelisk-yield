;; Title: Mock sBTC / Multi-Asset Token
;; Description: SIP-010 compliant mock asset representing Bitcoin (sBTC) on Stacks

(impl-trait .sip-010-trait.sip-010-trait)

(define-fungible-token mock-sbtc)

;; Constants & Error Codes
(define-constant ERR_NOT_OWNER (err u401))
(define-constant ERR_ZERO_AMOUNT (err u402))

(define-constant TOKEN_NAME "Mock sBTC Token")
(define-constant TOKEN_SYMBOL "msBTC")
(define-constant TOKEN_DECIMALS u8)
(define-constant TOKEN_URI (some u"https://obelisk.finance/metadata/msbtc.json"))

(define-data-var contract-owner principal tx-sender)

;; SIP-010 Transfer
(define-public (transfer
    (amount uint)
    (sender principal)
    (recipient principal)
    (memo (optional (buff 34)))
  )
  (begin
    (asserts! (or (is-eq tx-sender sender) (is-eq contract-caller sender))
      ERR_NOT_OWNER
    )
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (try! (ft-transfer? mock-sbtc amount sender recipient))
    (match memo
      to-print (print to-print)
      0x
    )
    (ok true)
  )
)

;; Minting function (owner-controlled for testing)
(define-public (mint
    (recipient principal)
    (amount uint)
  )
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_OWNER)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (ft-mint? mock-sbtc amount recipient)
  )
)

;; Burn function
(define-public (burn (amount uint))
  (begin
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (ft-burn? mock-sbtc amount tx-sender)
  )
)

(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_OWNER)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; Read-only SIP-010 getters
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
  (ok (ft-get-balance mock-sbtc account))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply mock-sbtc))
)

(define-read-only (get-token-uri)
  (ok TOKEN_URI)
)
