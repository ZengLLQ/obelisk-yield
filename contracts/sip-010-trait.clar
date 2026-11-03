;; Title: SIP-010 Fungible Token Trait
;; Description: Standard trait definition for fungible tokens on Stacks (SIP-010)

(define-trait sip-010-trait (
  ;; Transfer tokens to a recipient with an optional memo buffer
  (transfer
    (uint principal principal (optional (buff 34)))
    (response bool uint)
  )
  ;; Human-readable token name
  (get-name
    ()
    (response (string-ascii 32) uint)
  )
  ;; Human-readable token symbol
  (get-symbol
    ()
    (response (string-ascii 32) uint)
  )
  ;; Number of decimal places used for token representation
  (get-decimals
    ()
    (response uint uint)
  )
  ;; Balance for a specific account principal
  (get-balance
    (principal)
    (response uint uint)
  )
  ;; Total circulating supply of the token
  (get-total-supply
    ()
    (response uint uint)
  )
  ;; Optional URI string pointing to token metadata
  (get-token-uri
    ()
    (response (optional (string-utf8 256)) uint)
  )
))
