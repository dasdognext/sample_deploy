# *****************************************************************
# * Copyright (C) 2024  gNext Labs LLC - All Rights Reserved
# *
# * Unauthorized copying of this code, via any medium is strictly prohibited
# * Proprietary and confidential
# * Written by Abraham Lama Salomon <abraham.lama@gnextlabs.com>, 2021
# ******************************************************************
# A simple token-based authorizer example to demonstrate how to use an authorization token
# to allow or deny a request. In this example, the caller named 'user' is allowed to invoke
# a request if the client-supplied token value is 'allow'. The caller is not allowed to invoke
# the request if the token value is 'deny'. If the token value is 'unauthorized' or an empty
# string, the authorizer function returns an HTTP 401 status code. For any other token value,
# the authorizer returns an HTTP 500 status code.
# Note that token values are case-sensitive.
# D: is live!!!!

import json
import lambda_logger_format
import logging
import lambdawarmer
import os
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad
import base64
import time
from urllib.parse import unquote

logger = logging.getLogger("main")
logger.setLevel(logging.DEBUG)
logger.propagate = False  # Avoid propagation issues and duplication of logs in console
ch = logging.StreamHandler()  # sys.stdout
ch.setLevel(logging.DEBUG)  # use this one when debugging

# ch.setLevel(logging.INFO) # use this one for production
ch.setFormatter(lambda_logger_format.CustomFormatter())
logger.addHandler(ch)

verbose = True # Make this True to see all logs
SECRET_KEY_LAMBDA_AUTH = os.environ['SECRET_KEY_LAMBDA_AUTH']

def make_error_response(message, status_code):
    resp = {
        "statusCode": status_code,
        "body": json.dumps({"error": message}),
        "headers": {"Content-Type": "application/json"}
    }
    if verbose:
        logger.error(f"Returning error: {resp}")
    return resp

def make_success_response(body):
    resp = {
        "statusCode": 200,
        "body": json.dumps(body),
        "headers": {"Content-Type": "application/json"}
    }
    if verbose:
        logger.info(f"Returning success: {resp}")
    return resp

@lambdawarmer.warmer
def lambda_handler(event, context):
    query_params = event.get('queryStringParameters') or {}
    authorizationToken = query_params.get('api_key')
    
    # Validate authorization token exists
    if not authorizationToken:
        logger.warning("Authorization token (api_key) is missing from query parameters")
        return make_error_response("Missing authorization token (api_key)", 401)
    
    decrypted_text = decrypt_text(unquote(authorizationToken))
    
    # Check if decryption failed
    if decrypted_text == "error":
        logger.error("Failed to decrypt authorization token")
        return make_error_response("Invalid authorization token", 401)
    
    # "{$company->hash}:{$scope}:{$version}:{$hash}:{$main->id}{$time}"
    data = decrypted_text.split(":")
    
    # Validate data structure has minimum required fields
    if len(data) < 3:
        logger.error(f"Invalid decrypted token format. Expected at least 3 fields, got {len(data)}")
        return make_error_response("Invalid token format", 401)

    if data[1] != 'gnext':
        apiKey = encrypt_text(f"{data[0]}:gnext:{data[4]}")
        if len(data) >= 6:
            try:
                expiration_time = float(data[5])
                if expiration_time < time.time():
                    apiKey = "expired"
                    logger.info("api key expired")
            except ValueError:
                logger.error("Invalid expiration time format in data[5]")
                return make_error_response("Invalid expiration time format in token", 400)
        if apiKey == "expired":
            return make_error_response("API key expired", 401)
    else:
        apiKey = authorizationToken

    # Validate methodArn exists
    methodArn = event.get('methodArn')
    if not methodArn:
        logger.error("methodArn is missing from event")
        return make_error_response("Missing methodArn from event", 400)

    user = 'user|' + apiKey
    try:
        response_dict = generatePolicy(user, 'Allow', methodArn, apiKey)
    except Exception as ex:
        logger.exception("Unexpected error generating policy")
        # 500 for internal errors
        return make_error_response("Internal server error", 500)

    if verbose:
        logger.info(event)
        logger.info(json.dumps(response_dict))

    # Respond with the policy for the authorizer flow, it's NOT the proxy (i.e., no statusCode)
    return response_dict

def generatePolicy(principalId, effect, resource, authorizationToken):
    # Standard AWS Lambda authorizer response (no statusCode!):
    authResponse = {}
    authResponse['principalId'] = principalId
    if (effect and resource):
        policyDocument = {}
        policyDocument['Version'] = '2012-10-17'
        policyDocument['Statement'] = []
        statementOne = {}
        statementOne['Action'] = 'execute-api:Invoke'
        statementOne['Effect'] = effect
        statementOne['Resource'] = resource
        policyDocument['Statement'] = [statementOne]
        authResponse['policyDocument'] = policyDocument
    authResponse['context'] = {
        "stringKey": "stringval",
        "numberKey": 123,
        "booleanKey": True
    }
    authResponse['usageIdentifierKey'] = authorizationToken
    return authResponse  # for Lambda authorizer, must be a dict, not a JSON string

def base64url_decode(input):
    """
    Decodes a Base64URL encoded string.

    Args:
        input (str): The Base64URL encoded string.

    Returns:
        bytes: The decoded bytes.
    """
    input += '=' * (4 - (len(input) % 4))
    return base64.urlsafe_b64decode(input)

def decrypt_text(encrypted_text):
    """
    Decrypt the given text using AES encryption with the secret key.

    Args:
        encrypted_text (str): The encrypted text to decrypt.

    Returns:
        str: The decrypted text, or "error" if decryption fails.
    """
    try:
        cipher = AES.new(SECRET_KEY_LAMBDA_AUTH.encode("utf8"), AES.MODE_ECB)
        encrypted_text = base64url_decode(encrypted_text)
        decrypted_text = cipher.decrypt(encrypted_text)
        decrypted_text = unpad(decrypted_text, AES.block_size)
        return decrypted_text.decode("utf8")
    except Exception as e:
        error = f"There was an error processing decrypt_text: {e}"
        logger.error(error)
        return "error"
    
def encrypt_text(text):
    """
    Encrypts the given text using AES encryption in ECB mode.

    Args:
        text (str): The text to encrypt.

    Returns:
        str: The encrypted text encoded in Base64.

    Raises:
        ValueError: If the key is not the correct size for AES.
        TypeError: If the text or key are not of the correct type.
    """
    if isinstance(text, str):
        text = text.encode('utf-8')

    cipher = AES.new(SECRET_KEY_LAMBDA_AUTH.encode("utf8"), AES.MODE_ECB)

    padded_text = pad(text, AES.block_size)
    encrypted_text = cipher.encrypt(padded_text)

    return base64url_encode(encrypted_text)

def base64url_encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')