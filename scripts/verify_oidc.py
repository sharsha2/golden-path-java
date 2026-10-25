#!/usr/bin/env python3
"""Act like a cloud provider: verify a GitHub Actions OIDC token, then decide whether to trust it.

This is what Microsoft Entra ID, AWS IAM and Google Cloud do when a pipeline uses
"workload identity federation". Requires: pip install "pyjwt[crypto]"
"""
import os
import sys

import jwt
from jwt import PyJWKClient

ISSUER = "https://token.actions.githubusercontent.com"
JWKS_URL = f"{ISSUER}/.well-known/jwks"     # GitHub's public signing keys
AUDIENCE = "golden-path-lab"                # must match the audience the job asked for


def main() -> None:
    token = os.environ["OIDC_TOKEN"]
    allowed_subject = os.environ["ALLOWED_SUBJECT"]

    # Steps 3-4: find the right public key, then check signature, issuer, audience and expiry.
    try:
        signing_key = PyJWKClient(JWKS_URL).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],   # never accept "none" or let the token pick its own algorithm
            audience=AUDIENCE,
            issuer=ISSUER,
        )
    except jwt.PyJWTError as err:
        print(f"REJECTED: token is not valid: {err}")
        sys.exit(1)

    print("OK  signature, issuer, audience and expiry")
    for name in ("sub", "repository", "ref", "event_name", "job_workflow_ref", "actor"):
        print(f"    {name:17} {claims.get(name)}")

    # Step 5: the trust decision. A valid token is not enough; it must be the RIGHT identity.
    if claims.get("sub") != allowed_subject:
        print(f"REJECTED: subject {claims.get('sub')!r} is not trusted.")
        print(f"          Only {allowed_subject!r} may get cloud access.")
        sys.exit(1)

    print("ACCEPTED: a cloud provider would now issue a short-lived access token.")


if __name__ == "__main__":
    main()