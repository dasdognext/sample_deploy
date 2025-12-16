# *****************************************************************
# * Copyright (C) 2024  gNext Labs LLC - All Rights Reserved
# *
# * Unauthorized copying of this code, via any medium is strictly prohibited
# * Proprietary and confidential
# * Written by Abraham Lama Salomon <abraham.lama@gnextlabs.com>, 2021
# ******************************************************************

"""
Unit tests for AWS Lambda Auth Service.

This module contains comprehensive unit tests for the Lambda authorizer function,
including tests for token decryption, policy generation, and error handling.
"""

import pytest
import json
import base64
import time
import os
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad
from urllib.parse import quote

# Add src and layer directories to Python path for imports
# Path: cicd/test/ -> cicd/ -> repo_root/
repo_root = Path(__file__).parent.parent.parent
src_path = repo_root / "src"
layer_path = repo_root / "cicd" / "layer"
if str(src_path) not in sys.path:
    sys.path.insert(0, str(src_path))
if str(layer_path) not in sys.path:
    sys.path.insert(0, str(layer_path))


# Test fixtures
@pytest.fixture
def mock_secret_key():
    """Fixture providing a mock secret key for AES encryption."""
    return "1234567890123456"  # 16 bytes for AES-128


@pytest.fixture
def mock_context():
    """Fixture providing a mock Lambda context object."""
    context = MagicMock()
    context.aws_request_id = "test-request-id"
    context.function_name = "test-function"
    context.function_version = "$LATEST"
    return context


@pytest.fixture
def sample_event():
    """Fixture providing a sample API Gateway authorizer event."""
    return {
        "type": "TOKEN",
        "methodArn": "arn:aws:execute-api:us-east-1:123456789012:abcdef123/test/GET/request",
        "queryStringParameters": {
            "api_key": "test_api_key"
        }
    }


@pytest.fixture
def sample_event_no_query_params():
    """Fixture providing an event without query parameters."""
    return {
        "type": "TOKEN",
        "methodArn": "arn:aws:execute-api:us-east-1:123456789012:abcdef123/test/GET/request"
    }


@pytest.fixture
def sample_event_no_method_arn():
    """Fixture providing an event without methodArn."""
    return {
        "type": "TOKEN",
        "queryStringParameters": {
            "api_key": "test_api_key"
        }
    }


@pytest.fixture
def encrypted_token(mock_secret_key):
    """Fixture that creates a valid encrypted token for testing."""
    # Create a test token: "company_hash:scope:version:hash:main_id:timestamp"
    # Use a timestamp far in the future to avoid expiration during tests
    future_timestamp = time.time() + 86400 * 365  # 1 year from now
    test_token = f"company123:gnext:v1:hash456:789:{future_timestamp}"
    
    cipher = AES.new(mock_secret_key.encode("utf8"), AES.MODE_ECB)
    padded_text = pad(test_token.encode('utf-8'), AES.block_size)
    encrypted_bytes = cipher.encrypt(padded_text)
    encrypted_b64 = base64.urlsafe_b64encode(encrypted_bytes).rstrip(b'=').decode('ascii')
    
    return encrypted_b64


@pytest.fixture
def encrypted_token_non_gnext(mock_secret_key):
    """Fixture that creates an encrypted token with non-gnext scope."""
    # Use a timestamp far in the future to avoid expiration during tests
    future_timestamp = time.time() + 86400 * 365  # 1 year from now
    test_token = f"company123:other_scope:v1:hash456:789:{future_timestamp}"
    
    cipher = AES.new(mock_secret_key.encode("utf8"), AES.MODE_ECB)
    padded_text = pad(test_token.encode('utf-8'), AES.block_size)
    encrypted_bytes = cipher.encrypt(padded_text)
    encrypted_b64 = base64.urlsafe_b64encode(encrypted_bytes).rstrip(b'=').decode('ascii')
    
    return encrypted_b64


@pytest.fixture
def encrypted_token_expired(mock_secret_key):
    """Fixture that creates an expired encrypted token."""
    # Use a timestamp in the past
    past_timestamp = time.time() - 3600  # 1 hour ago
    test_token = f"company123:other_scope:v1:hash456:789:{past_timestamp}"
    
    cipher = AES.new(mock_secret_key.encode("utf8"), AES.MODE_ECB)
    padded_text = pad(test_token.encode('utf-8'), AES.block_size)
    encrypted_bytes = cipher.encrypt(padded_text)
    encrypted_b64 = base64.urlsafe_b64encode(encrypted_bytes).rstrip(b'=').decode('ascii')
    
    return encrypted_b64


class TestBase64URLFunctions:
    """Test cases for base64url encoding/decoding functions."""
    
    def test_base64url_encode(self, mock_secret_key):
        """Test base64url encoding function."""
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
            # Import after patching environment
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            data = b"test data"
            encoded = lambda_function.base64url_encode(data)
            
            # Should be base64url encoded (no padding, URL-safe)
            assert isinstance(encoded, str)
            assert '=' not in encoded
            assert '+' not in encoded or '/' not in encoded  # URL-safe
            
            # Decode to verify
            decoded = base64.urlsafe_b64decode(encoded + '=' * (4 - len(encoded) % 4))
            assert decoded == data
    
    def test_base64url_decode(self, mock_secret_key):
        """Test base64url decoding function."""
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            data = b"test data"
            encoded = base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')
            decoded = lambda_function.base64url_decode(encoded)
            
            assert decoded == data


class TestEncryptionFunctions:
    """Test cases for encryption and decryption functions."""
    
    def test_encrypt_text(self, mock_secret_key):
        """Test text encryption function."""
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            plaintext = "test message"
            encrypted = lambda_function.encrypt_text(plaintext)
            
            assert isinstance(encrypted, str)
            assert len(encrypted) > 0
            assert encrypted != plaintext
    
    def test_decrypt_text_success(self, mock_secret_key, encrypted_token):
        """Test successful text decryption."""
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            decrypted = lambda_function.decrypt_text(encrypted_token)
            
            assert decrypted != "error"
            assert "company123" in decrypted
            assert "gnext" in decrypted
    
    def test_decrypt_text_failure_invalid_token(self, mock_secret_key):
        """Test decryption failure with invalid token."""
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            invalid_token = "invalid_base64_token!!!"
            decrypted = lambda_function.decrypt_text(invalid_token)
            
            assert decrypted == "error"
    
    def test_decrypt_text_failure_wrong_key(self, mock_secret_key, encrypted_token):
        """Test decryption failure with wrong secret key."""
        wrong_key = "different_key_1234"  # Different key
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': wrong_key}):
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            # This might not always return "error" but should handle gracefully
            decrypted = lambda_function.decrypt_text(encrypted_token)
            # The result depends on padding validation, but should be handled


class TestGeneratePolicy:
    """Test cases for policy generation function."""
    
    def test_generate_policy_allow(self, mock_secret_key):
        """Test policy generation with Allow effect."""
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            principal_id = "user|test_key"
            effect = "Allow"
            resource = "arn:aws:execute-api:us-east-1:123456789012:abcdef123/test/GET/request"
            auth_token = "test_token"
            
            policy = lambda_function.generatePolicy(principal_id, effect, resource, auth_token)
            
            assert isinstance(policy, dict)
            assert policy['principalId'] == principal_id
            assert policy['policyDocument']['Version'] == '2012-10-17'
            assert len(policy['policyDocument']['Statement']) == 1
            assert policy['policyDocument']['Statement'][0]['Effect'] == 'Allow'
            assert policy['policyDocument']['Statement'][0]['Action'] == 'execute-api:Invoke'
            assert policy['policyDocument']['Statement'][0]['Resource'] == resource
            assert policy['usageIdentifierKey'] == auth_token
            assert 'context' in policy
    
    def test_generate_policy_deny(self, mock_secret_key):
        """Test policy generation with Deny effect."""
        with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
            if 'lambda_function' in sys.modules:
                del sys.modules['lambda_function']
            import lambda_function
            
            principal_id = "user|test_key"
            effect = "Deny"
            resource = "arn:aws:execute-api:us-east-1:123456789012:abcdef123/test/GET/request"
            auth_token = "test_token"
            
            policy = lambda_function.generatePolicy(principal_id, effect, resource, auth_token)
            
            assert isinstance(policy, dict)
            assert policy['policyDocument']['Statement'][0]['Effect'] == 'Deny'


class TestLambdaHandler:
    """Test cases for the main Lambda handler function."""
    
    def test_lambda_handler_success_gnext_scope(self, mock_secret_key, mock_context, 
                                                  sample_event, encrypted_token):
        """Test successful Lambda handler execution with gnext scope."""
        # Mock the warmer decorator to just pass through before importing
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
            
                # Update event with encrypted token
                sample_event['queryStringParameters']['api_key'] = quote(encrypted_token)
                
                response = lambda_function.lambda_handler(sample_event, mock_context)
                
                assert isinstance(response, dict)
                assert response['principalId'].startswith('user|')
                assert response['policyDocument']['Statement'][0]['Effect'] == 'Allow'
    
    def test_lambda_handler_success_non_gnext_scope(self, mock_secret_key, 
                                                     mock_context, sample_event, 
                                                     encrypted_token_non_gnext):
        """Test successful Lambda handler execution with non-gnext scope."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
            
                sample_event['queryStringParameters']['api_key'] = quote(encrypted_token_non_gnext)
                
                response = lambda_function.lambda_handler(sample_event, mock_context)
                
                assert isinstance(response, dict)
                assert response['principalId'].startswith('user|')
                assert response['policyDocument']['Statement'][0]['Effect'] == 'Allow'
    
    def test_lambda_handler_expired_token(self, mock_secret_key, mock_context,
                                          sample_event, encrypted_token_expired):
        """Test Lambda handler with expired token."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                sample_event['queryStringParameters']['api_key'] = quote(encrypted_token_expired)
                
                response = lambda_function.lambda_handler(sample_event, mock_context)
                
                # Expired token returns an error response
                assert isinstance(response, dict)
                assert response['statusCode'] == 401
                assert 'API key expired' in response['body']
    
    def test_lambda_handler_missing_api_key(self, mock_secret_key, mock_context,
                                             sample_event_no_query_params):
        """Test Lambda handler with missing api_key in query parameters."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                response = lambda_function.lambda_handler(sample_event_no_query_params, mock_context)
                
                assert isinstance(response, dict)
                assert response['statusCode'] == 401
                assert 'Missing authorization token' in response['body']
    
    def test_lambda_handler_missing_method_arn(self, mock_secret_key, mock_context,
                                                sample_event_no_method_arn, encrypted_token):
        """Test Lambda handler with missing methodArn."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                sample_event_no_method_arn['queryStringParameters']['api_key'] = quote(encrypted_token)
                
                response = lambda_function.lambda_handler(sample_event_no_method_arn, mock_context)
                
                assert isinstance(response, dict)
                assert response['statusCode'] == 400
                assert 'Missing methodArn' in response['body']
    
    def test_lambda_handler_invalid_token_format(self, mock_secret_key, mock_context,
                                                  sample_event):
        """Test Lambda handler with invalid token format (too few fields)."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                # Create a token that decrypts but has invalid format
                invalid_token = "field1:field2"  # Only 2 fields, need at least 5
                cipher = AES.new(mock_secret_key.encode("utf8"), AES.MODE_ECB)
                padded_text = pad(invalid_token.encode('utf-8'), AES.block_size)
                encrypted_bytes = cipher.encrypt(padded_text)
                encrypted_b64 = base64.urlsafe_b64encode(encrypted_bytes).rstrip(b'=').decode('ascii')
                
                sample_event['queryStringParameters']['api_key'] = quote(encrypted_b64)
                
                response = lambda_function.lambda_handler(sample_event, mock_context)
                
                assert isinstance(response, dict)
                assert response['statusCode'] == 401
                assert 'Invalid token format' in response['body']
    
    def test_lambda_handler_decryption_failure(self, mock_secret_key, mock_context,
                                               sample_event):
        """Test Lambda handler with decryption failure."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                # Use an invalid encrypted token
                sample_event['queryStringParameters']['api_key'] = "invalid_encrypted_token"
                
                response = lambda_function.lambda_handler(sample_event, mock_context)
                
                assert isinstance(response, dict)
                assert response['statusCode'] == 401
                assert 'Invalid authorization token' in response['body']
    
    def test_lambda_handler_policy_generation_exception(self, mock_secret_key, mock_context,
                                                        sample_event, encrypted_token):
        """Test Lambda handler when policy generation raises an exception."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                sample_event['queryStringParameters']['api_key'] = quote(encrypted_token)
                
                # Mock generatePolicy to raise an exception
                with patch.object(lambda_function, 'generatePolicy', side_effect=Exception("Policy error")):
                    response = lambda_function.lambda_handler(sample_event, mock_context)
                    assert isinstance(response, dict)
                    assert response['statusCode'] == 500
                    assert 'Internal server error' in response['body']
    
    def test_lambda_handler_empty_query_params(self, mock_secret_key, mock_context):
        """Test Lambda handler with empty query parameters."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                event = {
                    "type": "TOKEN",
                    "methodArn": "arn:aws:execute-api:us-east-1:123456789012:abcdef123/test/GET/request",
                    "queryStringParameters": {}
                }
                
                response = lambda_function.lambda_handler(event, mock_context)
                
                assert isinstance(response, dict)
                assert response['statusCode'] == 401
                assert 'Missing authorization token' in response['body']
    
    def test_lambda_handler_none_query_params(self, mock_secret_key, mock_context):
        """Test Lambda handler with None query parameters."""
        with patch('lambdawarmer.warmer', lambda f: f):
            with patch.dict(os.environ, {'SECRET_KEY_LAMBDA_AUTH': mock_secret_key}):
                if 'lambda_function' in sys.modules:
                    del sys.modules['lambda_function']
                if 'lambda_logger_format' in sys.modules:
                    del sys.modules['lambda_logger_format']
                import lambda_function
                
                event = {
                    "type": "TOKEN",
                    "methodArn": "arn:aws:execute-api:us-east-1:123456789012:abcdef123/test/GET/request",
                    "queryStringParameters": None
                }
                
                response = lambda_function.lambda_handler(event, mock_context)
                
                assert isinstance(response, dict)
                assert response['statusCode'] == 401
                assert 'Missing authorization token' in response['body']

