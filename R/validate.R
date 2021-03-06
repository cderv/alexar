#' Validate an Alexa Request
#'
#' Validate that an incoming request is legitimate (i.e. from Amazon). This
#' validation on incoming requests is not only important for security, but also
#' required in order for Amazon to certify your Alexa custom skill.
#'
#' See
#' https://developer.amazon.com/public/solutions/alexa/alexa-skills-kit/docs/developing-an-alexa-skill-as-a-web-service#h2_verify_sig_cert
#' for more details.
#' @include globals.R
#' @import openssl
#' @import urltools
#' @param req The incoming plumber request to validate
#' @export
validateAlexaRequest <- function(req){
  doValidate(req)
}

# Internal function that allows for mocking of some system-level calls
#' @importFrom utils download.file
#' @noRd
doValidate <- function(req, now=Sys.time(), download=download.file){
  # TODO: cache cert URL handling

  # 1. Verify that the URL matches the format used by amazon
  # TODO: normalize URL of ../s
  certURL <- req$HTTP_SIGNATURECERTCHAINURL
  parsed <- as.list(urltools::url_parse(certURL))
  if (tolower(parsed$scheme) != "https"){
    stop("Provided certificate protocol is not HTTPS")
  }

  if (tolower(parsed$domain) != "s3.amazonaws.com") {
    stop("Provide certificate host name is not s3.amazonaws.com")
  }

  if (!grepl("^echo.api\\/", parsed$path)){
    stop("Provided certificate path does not begin with `echo.api/`")
  }

  if (!is.na(parsed$port) && parsed$port != 443){
    stop("Provided certificate port was not empty or 443")
  }


  # 2. Download the PEM Cert file
  crtFile <- tempfile(fileext=".crt")
  download(certURL, crtFile)
  chain <- openssl::read_cert_bundle(crtFile)
  file.remove(crtFile)

  # 3.
  #   3a. Check the `Not Before` and `Not After` dates
  validity <- as.list(chain[[1]])$validity
  start <- strptime(validity[1], "%b %e %H:%M:%S %Y", tz="GMT")
  end <- strptime(validity[2], "%b %e %H:%M:%S %Y", tz="GMT")

  if (start > now){
    stop("Certificate validity set to start in the future")
  }

  if (end < now){
    stop("Certificate has expired")
  }

  #   3b. Check that it's an echo domain cert
  forEcho <- grepl("echo-api.amazon.com", as.list(chain[[1]])$subject, fixed = TRUE)
  if (!forEcho){
    stop("Invalid cert domain")
  }

  #   3c. Chain points to a trusted root CA
  valid <- openssl::cert_verify(chain)
  if (!valid){
    stop("Invalid cert!")
  }

  # 4. Get the public key from the cert
  pubkey <- openssl::read_pubkey(chain[[1]])

  # 5. Base64-decode the Signature header value
  encSig <- openssl::base64_decode(req$HTTP_SIGNATURE)

  # 6. Decrypt the encrypted hash value
  # 7. Generate the SHA1 hash of the request body
  # 8. Compare the hashes
  postBody <- req$postBody
  openssl::signature_verify(data=charToRaw(postBody), sig=encSig, hash=openssl::sha1, pubkey=pubkey)

  # 9. Check timestamp
  ts <- req$args$request$timestamp
  time <- strptime(ts, format="%Y-%m-%dT%H:%M:%SZ", tz="GMT")
  delta <- as.integer(difftime(time, now, units="secs"))
  if (abs(delta) > 150){
    stop("Timestamp on request differs by ", delta, " seconds. Must be within 150.")
  }
}


