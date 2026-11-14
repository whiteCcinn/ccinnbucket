"""Generates reference signing vectors with the official SDKs.

The SDKs are NOT project dependencies. Run this script from a throw-away virtualenv:

    python3 -I -m venv /tmp/ccinnbucket-vectors
    /tmp/ccinnbucket-vectors/bin/python -I -m pip install botocore oss2 alibabacloud-oss-v2
    /tmp/ccinnbucket-vectors/bin/python -I scripts/vectors/generate_signing_vectors.py Tests/StorageSigningTests/Fixtures

Every expected value is computed by SDK code (botocore's SigV4 classes and percent encoder,
alibabacloud-oss-v2's SignerV4, oss2's V1 Auth) with a fixed clock. Nothing is hand-written.
"""
import base64
import copy
import datetime
import hashlib
import json
import os
import sys
from urllib.parse import urlsplit, quote

import botocore
import botocore.auth
import botocore.utils
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

import oss2
import oss2.auth
import oss2.utils
import alibabacloud_oss_v2 as oss_v2
from alibabacloud_oss_v2.signer import SignerV4
from alibabacloud_oss_v2.types import HttpRequest, SigningContext
from alibabacloud_oss_v2.credentials import StaticCredentialsProvider as V2Static

EXAMPLE_KEY_ID = 'AKIAIOSFODNN7EXAMPLE'
EXAMPLE_SECRET = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
STS_KEY_ID = 'ASIAEXAMPLESTSKEY123'
STS_SECRET = 'Tmp/Secret+Key=Example0123456789abcdefGH'
STS_TOKEN = 'IQoJb3JpZ2luX2VjEXAMPLE/token+with=special&chars=='
OSS_KEY_ID = 'LTAI5tEXAMPLEaccessKey'
OSS_SECRET = 'OSSExampleSecret0123456789abcdef'
OSS_STS_KEY_ID = 'STS.NUexampleAccessKeyId'
OSS_STS_SECRET = 'STSexampleSecret/With+Slash='
OSS_STS_TOKEN = 'CAIS+example/sts=token&value=='

CREDENTIALS = {
    'example': (EXAMPLE_KEY_ID, EXAMPLE_SECRET, None),
    'sts': (STS_KEY_ID, STS_SECRET, STS_TOKEN),
    'oss': (OSS_KEY_ID, OSS_SECRET, None),
    'oss-sts': (OSS_STS_KEY_ID, OSS_STS_SECRET, OSS_STS_TOKEN),
}

FIXED = datetime.datetime(2026, 11, 14, 8, 30, 15, tzinfo=datetime.timezone.utc)
AWS_DOC_TIME = datetime.datetime(2013, 5, 24, 0, 0, 0, tzinfo=datetime.timezone.utc)


def b64(data):
    return base64.b64encode(data).decode('ascii') if data is not None else None


# ---------------------------------------------------------------------------
# AWS SigV4 (botocore)
# ---------------------------------------------------------------------------

class _S3Config:
    def __init__(self, sign_payload):
        self.s3 = {'payload_signing_enabled': sign_payload}


def aws_url(scheme, host, path, query):
    encoded_path = botocore.utils.percent_encode(path, safe='/~')
    url = f'{scheme}://{host}{encoded_path}'
    if query:
        url += '?' + botocore.utils.percent_encode_sequence(query)
    return url, encoded_path


def sign_aws_header(case):
    key_id, secret, token = CREDENTIALS[case['credentials']]
    when = AWS_DOC_TIME if case.get('awsDoc') else FIXED
    botocore.auth.get_current_datetime = lambda: when.replace(tzinfo=None)
    url, encoded_path = aws_url(case['scheme'], case['host'], case['path'], case.get('query', []))
    body = case['body'].encode('utf-8') if case.get('body') is not None else b''
    headers = {name: value for name, value in case.get('headers', [])}
    request = AWSRequest(method=case['method'], url=url, data=body, headers=headers)
    if case.get('unsignedPayload'):
        request.context['client_config'] = _S3Config(False)
    auth = botocore.auth.S3SigV4Auth(Credentials(key_id, secret, token), 's3', case['region'])

    # Mirror add_auth() step by step (same SDK methods) to capture the intermediate strings.
    request.context['timestamp'] = when.strftime(botocore.auth.SIGV4_TIMESTAMP)
    auth._modify_request_before_signing(request)
    canonical_request = auth.canonical_request(request)
    string_to_sign = auth.string_to_sign(request, canonical_request)
    signature = auth.signature(string_to_sign, request)
    auth._inject_signature_to_request(request, signature)

    # Cross-check against an untouched add_auth() run.
    check = AWSRequest(method=case['method'], url=url, data=body, headers=dict(headers))
    if case.get('unsignedPayload'):
        check.context['client_config'] = _S3Config(False)
    botocore.auth.S3SigV4Auth(Credentials(key_id, secret, token), 's3', case['region']).add_auth(check)
    assert check.headers['Authorization'] == request.headers['Authorization'], case['name']

    out = dict(case)
    out['url'] = url
    out['timestamp'] = request.context['timestamp']
    out['expected'] = {
        'encodedPath': encoded_path,
        'canonicalRequest': canonical_request,
        'stringToSign': string_to_sign,
        'signature': signature,
        'authorization': request.headers['Authorization'],
        'payloadHash': request.headers['X-Amz-Content-SHA256'],
        'amzDate': request.headers.get('X-Amz-Date'),
        'securityToken': request.headers.get('X-Amz-Security-Token'),
    }
    return out


def sign_aws_doc_raw(case):
    """AWS-documented examples that carry their own date headers: canonicalise with botocore methods."""
    key_id, secret, token = CREDENTIALS[case['credentials']]
    url, encoded_path = aws_url(case['scheme'], case['host'], case['path'], case.get('query', []))
    headers = {name: value for name, value in case.get('headers', [])}
    request = AWSRequest(method=case['method'], url=url, data=b'', headers=headers)
    request.context['timestamp'] = AWS_DOC_TIME.strftime(botocore.auth.SIGV4_TIMESTAMP)
    auth = botocore.auth.S3SigV4Auth(Credentials(key_id, secret, token), 's3', case['region'])
    canonical_request = auth.canonical_request(request)
    string_to_sign = auth.string_to_sign(request, canonical_request)
    signature = auth.signature(string_to_sign, request)
    auth._inject_signature_to_request(request, signature)
    out = dict(case)
    out['url'] = url
    out['timestamp'] = request.context['timestamp']
    out['expected'] = {
        'encodedPath': encoded_path,
        'canonicalRequest': canonical_request,
        'stringToSign': string_to_sign,
        'signature': signature,
        'authorization': request.headers['Authorization'],
        'payloadHash': headers.get('x-amz-content-sha256'),
        'amzDate': headers.get('x-amz-date'),
        'securityToken': None,
    }
    return out


def presign_aws(case):
    key_id, secret, token = CREDENTIALS[case['credentials']]
    when = AWS_DOC_TIME if case.get('awsDoc') else FIXED
    botocore.auth.get_current_datetime = lambda: when.replace(tzinfo=None)
    url, encoded_path = aws_url(case['scheme'], case['host'], case['path'], case.get('query', []))
    headers = {name: value for name, value in case.get('headers', [])}
    request = AWSRequest(method=case['method'], url=url, data=b'', headers=headers)
    auth = botocore.auth.S3SigV4QueryAuth(Credentials(key_id, secret, token), 's3', case['region'], expires=case['expires'])
    request.context['timestamp'] = when.strftime(botocore.auth.SIGV4_TIMESTAMP)
    auth._modify_request_before_signing(request)
    canonical_request = auth.canonical_request(request)
    string_to_sign = auth.string_to_sign(request, canonical_request)
    signature = auth.signature(string_to_sign, request)
    auth._inject_signature_to_request(request, signature)

    check = AWSRequest(method=case['method'], url=url, data=b'', headers=dict(headers))
    botocore.auth.S3SigV4QueryAuth(Credentials(key_id, secret, token), 's3', case['region'], expires=case['expires']).add_auth(check)
    assert check.url == request.url, case['name']

    out = dict(case)
    out['timestamp'] = request.context['timestamp']
    out['expected'] = {
        'encodedPath': encoded_path,
        'canonicalRequest': canonical_request,
        'stringToSign': string_to_sign,
        'signature': signature,
        'url': request.url,
    }
    return out


SPECIAL_KEY = "a+b~c d%e&f=g@h:i,j;k$l!m'n(o)p*q[r]s#t?u"
UNICODE_KEY = 'photos/2024/日本語 ファイル/naïve café ✓.txt'

AWS_HEADER_CASES = [
    # --- AWS documentation examples (Signature Calculations for the Authorization Header) ---
    {'name': 'aws-doc-get-object', 'awsDoc': True, 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'https', 'host': 'examplebucket.s3.amazonaws.com', 'path': '/test.txt',
     'headers': [['Range', 'bytes=0-9']], 'documentedSignature': 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41'},
    {'name': 'aws-doc-get-lifecycle', 'awsDoc': True, 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'https', 'host': 'examplebucket.s3.amazonaws.com', 'path': '/', 'query': [['lifecycle', '']],
     'documentedSignature': 'fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543'},
    {'name': 'aws-doc-list-objects', 'awsDoc': True, 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'https', 'host': 'examplebucket.s3.amazonaws.com', 'path': '/', 'query': [['max-keys', '2'], ['prefix', 'J']],
     'documentedSignature': '34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7'},
    # --- Generated with a fixed clock ---
    {'name': 'path-style-unicode-key', 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'http', 'host': '127.0.0.1:19900', 'path': '/ccinn-demo/' + UNICODE_KEY},
    {'name': 'virtual-special-characters', 'credentials': 'example', 'region': 'eu-west-1', 'method': 'PUT',
     'scheme': 'https', 'host': 'bucket.s3.eu-west-1.amazonaws.com', 'path': '/' + SPECIAL_KEY,
     'headers': [['Content-Type', 'text/plain; charset=utf-8'], ['x-amz-meta-note', '  spaced   value  ']],
     'body': 'hello, signed world\n'},
    {'name': 'double-slash-and-dots', 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'https', 'host': 'bucket.s3.amazonaws.com', 'path': '/a//b/./c/../d'},
    {'name': 'folder-marker-put', 'credentials': 'example', 'region': 'us-west-2', 'method': 'PUT',
     'scheme': 'https', 'host': 's3.us-west-2.amazonaws.com', 'path': '/my.dotted.bucket/folder/sub folder/', 'body': ''},
    {'name': 'list-v2-query', 'credentials': 'example', 'region': 'ap-southeast-1', 'method': 'GET',
     'scheme': 'https', 'host': 'bucket.s3.ap-southeast-1.amazonaws.com', 'path': '/',
     'query': [['list-type', '2'], ['delimiter', '/'], ['prefix', 'logs/2026 11/日志/'], ['encoding-type', 'url'],
               ['continuation-token', '1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM='], ['max-keys', '1000'],
               ['start-after', 'a+b c~d']]},
    {'name': 'list-empty-prefix', 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'http', 'host': 'localhost:9000', 'path': '/bucket/',
     'query': [['list-type', '2'], ['prefix', ''], ['delimiter', '/'], ['encoding-type', 'url']]},
    {'name': 'sts-session-token', 'credentials': 'sts', 'region': 'eu-central-1', 'method': 'HEAD',
     'scheme': 'https', 'host': 'bucket.s3.eu-central-1.amazonaws.com', 'path': '/reports/q3.pdf',
     'query': [['versionId', '3/L4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vjVBH40Nr8X8gdRQBpUMLUo']]},
    {'name': 'unsigned-payload-put', 'credentials': 'example', 'region': 'us-east-1', 'method': 'PUT',
     'scheme': 'https', 'host': 'bucket.s3.amazonaws.com', 'path': '/big/file.bin',
     'headers': [['Content-MD5', '1B2M2Y8AsgTpgAmY7PhCfg==']], 'body': '', 'unsignedPayload': True},
    {'name': 'create-multipart', 'credentials': 'example', 'region': 'us-east-1', 'method': 'POST',
     'scheme': 'https', 'host': 'bucket.s3.amazonaws.com', 'path': '/videos/movie.mp4', 'query': [['uploads', '']],
     'headers': [['Content-Type', 'video/mp4'], ['x-amz-storage-class', 'STANDARD_IA']], 'body': ''},
    {'name': 'upload-part', 'credentials': 'example', 'region': 'us-east-1', 'method': 'PUT',
     'scheme': 'https', 'host': 'bucket.s3.amazonaws.com', 'path': '/videos/movie.mp4',
     'query': [['partNumber', '7'], ['uploadId', 'VXBsb2FkIElEIGZvciBlbHZpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA']],
     'body': 'part-body-bytes'},
    {'name': 'copy-object-replace-metadata', 'credentials': 'example', 'region': 'us-east-1', 'method': 'PUT',
     'scheme': 'http', 'host': '127.0.0.1:19900', 'path': '/dst-bucket/copied/ü file.txt',
     'headers': [['x-amz-copy-source', '/src-bucket/' + quote('orig/ü file.txt', safe='/~') + '?versionId=abc'],
                 ['x-amz-metadata-directive', 'REPLACE'], ['Content-Type', 'text/html'], ['x-amz-meta-owner', 'Ccinn']],
     'body': ''},
    {'name': 'delete-objects', 'credentials': 'example', 'region': 'us-east-1', 'method': 'POST',
     'scheme': 'http', 'host': '127.0.0.1:19900', 'path': '/bucket/', 'query': [['delete', '']],
     'headers': [['Content-Type', 'application/xml'], ['Content-MD5', 'placeholder-md5==']],
     'body': '<Delete><Quiet>true</Quiet><Object><Key>a&amp;b</Key></Object></Delete>'},
    {'name': 'list-buckets', 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'https', 'host': 's3.amazonaws.com', 'path': '/'},
]

AWS_PRESIGN_CASES = [
    {'name': 'aws-doc-presign-get', 'awsDoc': True, 'credentials': 'example', 'region': 'us-east-1', 'method': 'GET',
     'scheme': 'https', 'host': 'examplebucket.s3.amazonaws.com', 'path': '/test.txt', 'expires': 86400,
     'documentedSignature': 'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404'},
    {'name': 'presign-sts-version-disposition', 'credentials': 'sts', 'region': 'eu-central-1', 'method': 'GET',
     'scheme': 'https', 'host': 'bucket.s3.eu-central-1.amazonaws.com', 'path': '/' + UNICODE_KEY, 'expires': 3600,
     'query': [['versionId', 'v+1/2=='], ['response-content-disposition', 'attachment; filename="résumé.pdf"']]},
    {'name': 'presign-path-style-put', 'credentials': 'example', 'region': 'us-east-1', 'method': 'PUT',
     'scheme': 'http', 'host': '127.0.0.1:19900', 'path': '/ccinn-demo/uploads/' + SPECIAL_KEY, 'expires': 604800},
]


# ---------------------------------------------------------------------------
# OSS V4 (alibabacloud-oss-v2)
# ---------------------------------------------------------------------------

def oss_url(scheme, host, bucket, key, query, path_style=False):
    # Mirrors alibabacloud_oss_v2._client._build_url and its urlencode(quote_via=quote).
    from urllib.parse import urlencode
    if bucket is None:
        path = '/'
    elif path_style:
        path = '/' + bucket + '/' + (quote(key) if key is not None else '')
    else:
        path = '/' + (quote(key) if key is not None else '')
    url = f'{scheme}://{host}{path}'
    if query:
        url += '?' + urlencode([tuple(item) for item in query], quote_via=quote)
    return url, path


def sign_oss_v4(case):
    key_id, secret, token = CREDENTIALS[case['credentials']]
    url, encoded_path = oss_url(case['scheme'], case['host'], case.get('bucket'), case.get('key'), case.get('query', []))
    headers = {name: value for name, value in case.get('headers', [])}
    request = HttpRequest(case['method'], url, headers=headers)
    credentials = V2Static(key_id, secret, token).get_credentials()
    ctx = SigningContext(product='oss', region=case['region'], bucket=case.get('bucket'), key=case.get('key'),
                         request=request, credentials=credentials, signing_time=FIXED,
                         additional_headers=set(case.get('additionalHeaders', [])) or None)
    expected = {'encodedPath': encoded_path}
    if case.get('expires') is not None:
        ctx.auth_method_query = True
        ctx.expiration_time = FIXED + datetime.timedelta(seconds=case['expires'])
        SignerV4().sign(ctx)
        expected['url'] = request.url
    else:
        SignerV4().sign(ctx)
        expected['authorization'] = request.headers['Authorization']
        expected['ossDate'] = request.headers['x-oss-date']
        expected['date'] = request.headers['Date']
        expected['contentSHA256'] = request.headers['x-oss-content-sha256']
        expected['securityToken'] = request.headers.get('x-oss-security-token')
    expected['stringToSign'] = ctx.string_to_sign
    if case.get('expires') is None:
        _crosscheck_oss4_with_oss2(case, url, key_id, secret, token, expected['authorization'])
    out = dict(case)
    out['url'] = url
    out['timestamp'] = FIXED.strftime('%Y%m%dT%H%M%SZ')
    out['expected'] = expected
    return out


def _crosscheck_oss4_with_oss2(case, url, key_id, secret, token, authorization):
    """The two official OSS SDKs must agree on every V4 header signature."""
    import re

    class _Fixed(datetime.datetime):
        @classmethod
        def utcnow(cls):
            return FIXED.replace(tzinfo=None)

    oss2.auth.datetime = _Fixed
    provider = oss2.credentials.StaticCredentialsProvider(key_id, secret, token)
    headers = {name: value for name, value in case.get('headers', [])}
    params = {name: value for name, value in case.get('query', [])}
    req = oss2.http.Request(case['method'], url.split('?')[0], params=params, headers=headers,
                            region=case['region'], product='oss')
    oss2.auth.ProviderAuthV4(provider)._sign_request(req, case.get('bucket') or '', case.get('key') or '',
                                                     set(case.get('additionalHeaders', [])) or None)
    ours = re.search(r'Signature=([0-9a-f]+)', authorization).group(1)
    theirs = re.search(r'Signature=([0-9a-f]+)', req.headers['authorization']).group(1)
    assert ours == theirs, case['name']


OSS_V4_CASES = [
    {'name': 'oss4-put-object', 'credentials': 'oss', 'region': 'cn-hangzhou', 'method': 'PUT', 'scheme': 'https',
     'host': 'examplebucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'examplebucket', 'key': 'exampleobject',
     'headers': [['Content-Type', 'text/plain'], ['x-oss-meta-author', 'ccinn'], ['x-oss-storage-class', 'IA']]},
    {'name': 'oss4-get-unicode-subresources', 'credentials': 'oss', 'region': 'cn-shanghai', 'method': 'GET', 'scheme': 'https',
     'host': 'bucket-a.oss-cn-shanghai.aliyuncs.com', 'bucket': 'bucket-a', 'key': UNICODE_KEY,
     'query': [['versionId', 'CAEQNhiBgM0BYiIDc4MGZjZGI2OTBjOTRmNTE5NmU5NmFhZjhjYmY0'],
               ['response-content-disposition', 'attachment; filename="résumé.pdf"']]},
    {'name': 'oss4-list-v2', 'credentials': 'oss', 'region': 'cn-hangzhou', 'method': 'GET', 'scheme': 'https',
     'host': 'bucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'bucket',
     'query': [['list-type', '2'], ['prefix', ''], ['delimiter', '/'], ['encoding-type', 'url'], ['max-keys', '1000'],
               ['continuation-token', 'ChR0ZXN0L+aXpeacrC8xLnR4dBAA']]},
    {'name': 'oss4-special-key-additional-host', 'credentials': 'oss', 'region': 'ap-southeast-1', 'method': 'DELETE',
     'scheme': 'https', 'host': 'bkt.oss-ap-southeast-1.aliyuncs.com', 'bucket': 'bkt', 'key': SPECIAL_KEY,
     'headers': [['Host', 'bkt.oss-ap-southeast-1.aliyuncs.com']], 'additionalHeaders': ['host']},
    {'name': 'oss4-initiate-multipart-sts', 'credentials': 'oss-sts', 'region': 'cn-beijing', 'method': 'POST',
     'scheme': 'https', 'host': 'bkt.oss-cn-beijing.aliyuncs.com', 'bucket': 'bkt', 'key': 'big/file.iso',
     'query': [['uploads', '']], 'headers': [['Content-Type', 'application/octet-stream']]},
    {'name': 'oss4-delete-multiple', 'credentials': 'oss', 'region': 'cn-hangzhou', 'method': 'POST', 'scheme': 'https',
     'host': 'bkt.oss-cn-hangzhou-internal.aliyuncs.com', 'bucket': 'bkt', 'query': [['delete', '']],
     'headers': [['Content-Type', 'application/xml'], ['Content-MD5', 'kO0r1Yw6dyP2yO8x7zE1oA==']]},
    {'name': 'oss4-list-buckets', 'credentials': 'oss', 'region': 'cn-hangzhou', 'method': 'GET', 'scheme': 'https',
     'host': 'oss-cn-hangzhou.aliyuncs.com'},
    {'name': 'oss4-presign-get', 'credentials': 'oss', 'region': 'cn-hangzhou', 'method': 'GET', 'scheme': 'https',
     'host': 'examplebucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'examplebucket', 'key': 'dir/示例 file.txt',
     'expires': 3600},
    {'name': 'oss4-presign-sts-version', 'credentials': 'oss-sts', 'region': 'eu-central-1', 'method': 'GET', 'scheme': 'https',
     'host': 'bkt.oss-eu-central-1.aliyuncs.com', 'bucket': 'bkt', 'key': 'a b+c', 'query': [['versionId', 'v1/2+3']],
     'expires': 604800},
]


# ---------------------------------------------------------------------------
# OSS V1 (oss2)
# ---------------------------------------------------------------------------

def sign_oss_v1(case):
    key_id, secret, token = CREDENTIALS[case['credentials']]
    if token:
        auth = oss2.StsAuth(key_id, secret, token)._StsAuth__auth
    else:
        auth = oss2.Auth(key_id, secret)
    http_date = 'Sat, 14 Nov 2026 08:30:15 GMT'
    oss2.auth.utils.http_date = lambda *args, **kwargs: http_date
    headers = {name: value for name, value in case.get('headers', [])}
    params = {name: value for name, value in case.get('query', [])}
    bucket = case.get('bucket') or ''
    key = case.get('key') or ''
    endpoint_host = case['host'][len(bucket) + 1:] if bucket else case['host']
    url = oss2.api._UrlMaker(f"{case['scheme']}://{endpoint_host}", False, False)(bucket, key, slash_safe=True)
    req = oss2.http.Request(case['method'], url, params=dict(params), headers=headers)
    expected = {}
    if case.get('expiresAt') is not None:
        oss2.auth.time.time = lambda: case['expiresAt'] - case['expires']
        signed = auth._sign_url(req, bucket, key, case['expires'])
        expected['url'] = signed
        expected['signature'] = req.params['Signature']
        expected['securityToken'] = req.params.get('security-token')
    else:
        auth._sign_request(req, bucket, key)
        expected['authorization'] = req.headers['authorization']
        expected['date'] = req.headers['date']
        expected['securityToken'] = req.headers.get('x-oss-security-token')
    out = dict(case)
    out['expected'] = expected
    return out


OSS_V1_CASES = [
    {'name': 'oss1-put-object', 'credentials': 'oss', 'method': 'PUT', 'scheme': 'https',
     'host': 'examplebucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'examplebucket', 'key': 'nelson',
     'headers': [['Content-MD5', 'eB5eJF1ptWaXm4bijSPyxw=='], ['Content-Type', 'text/html'],
                 ['x-oss-meta-author', 'foo@bar.com'], ['x-oss-magic', 'abracadabra']]},
    {'name': 'oss1-get-acl', 'credentials': 'oss', 'method': 'GET', 'scheme': 'https',
     'host': 'bucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'bucket', 'key': '', 'query': [['acl', '']]},
    {'name': 'oss1-get-object-response-overrides', 'credentials': 'oss', 'method': 'GET', 'scheme': 'https',
     'host': 'bucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'bucket', 'key': UNICODE_KEY,
     'query': [['response-content-type', 'text/plain'], ['versionId', 'v1'], ['x-irrelevant', 'not-signed']]},
    {'name': 'oss1-list-v2', 'credentials': 'oss', 'method': 'GET', 'scheme': 'https',
     'host': 'bucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'bucket', 'key': '',
     'query': [['list-type', '2'], ['prefix', 'a/'], ['delimiter', '/'], ['continuation-token', 'tok/en+=='],
               ['encoding-type', 'url']]},
    {'name': 'oss1-upload-part-sts', 'credentials': 'oss-sts', 'method': 'PUT', 'scheme': 'https',
     'host': 'bucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'bucket', 'key': 'big/file.iso',
     'query': [['partNumber', '3'], ['uploadId', '0004B9895DBBB6EC98E36']],
     'headers': [['Content-MD5', 'kO0r1Yw6dyP2yO8x7zE1oA==']]},
    {'name': 'oss1-list-buckets', 'credentials': 'oss', 'method': 'GET', 'scheme': 'https',
     'host': 'oss-cn-hangzhou.aliyuncs.com'},
    {'name': 'oss1-presign-get', 'credentials': 'oss', 'method': 'GET', 'scheme': 'https',
     'host': 'bucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'bucket', 'key': 'dir/示例 file.txt',
     'expires': 3600, 'expiresAt': 1794645015},
    {'name': 'oss1-presign-sts-version', 'credentials': 'oss-sts', 'method': 'GET', 'scheme': 'https',
     'host': 'bucket.oss-cn-hangzhou.aliyuncs.com', 'bucket': 'bucket', 'key': 'a b+c',
     'query': [['versionId', 'v1/2+3']], 'expires': 600, 'expiresAt': 1794642015},
]


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.makedirs(out_dir, exist_ok=True)
    meta = {
        'generator': 'scripts/vectors/generate_signing_vectors.py',
        'sdks': {'botocore': botocore.__version__, 'oss2': oss2.__version__,
                 'alibabacloud-oss-v2': getattr(oss_v2, '__version__', 'unknown')},
        'credentials': {name: {'accessKeyID': v[0], 'secretAccessKey': v[1], 'sessionToken': v[2]}
                        for name, v in CREDENTIALS.items()},
    }
    aws = []
    for case in AWS_HEADER_CASES:
        aws.append(sign_aws_doc_raw(dict(case, headers=case.get('headers', []) + [
            ['x-amz-content-sha256', hashlib.sha256(b'').hexdigest()], ['x-amz-date', '20130524T000000Z']]))
                   if case.get('awsDoc') else sign_aws_header(case))
    presign = [presign_aws(case) for case in AWS_PRESIGN_CASES]
    oss4 = [sign_oss_v4(case) for case in OSS_V4_CASES]
    oss1 = [sign_oss_v1(case) for case in OSS_V1_CASES]
    for case in aws + presign:
        if 'documentedSignature' in case:
            assert case['expected']['signature'] == case['documentedSignature'], case['name']
    files = {
        'aws-sigv4-header.json': aws,
        'aws-sigv4-presign.json': presign,
        'oss-v4.json': oss4,
        'oss-v1.json': oss1,
    }
    for name, cases in files.items():
        with open(os.path.join(out_dir, name), 'w', encoding='utf-8') as handle:
            json.dump(dict(meta, cases=cases), handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write('\n')
        print(f'wrote {len(cases)} cases to {name}')


if __name__ == '__main__':
    main()
