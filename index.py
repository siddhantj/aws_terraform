import os
os.environ['AWS_DATA_PATH'] = '/opt/'

from itertools import islice
import boto3
from datetime import datetime
import time
import json

region = os.environ['AWS_REGION']
destination_bucket = os.environ['S3_BUCKET']

if not destination_bucket:
    raise Exception("'S3_BUCKET' environment variable must be defined!")

def handler(event, context):
    dataexchange = boto3.client(
        service_name='dataexchange',
        region_name=region
    )
    s3 = boto3.client(
        service_name='s3',
        region_name=region
    )
    sqs = boto3.client(
        service_name='sqs',
        region_name=region
    )
    message = sqs.receive_message(
        QueueUrl='https://sqs.us-east-1.amazonaws.com/635065826439/adx_sqs_queue'
    )
    print("##### Event -- START")
    print(message)
    print("##### Event -- END")
    return {
        'statusCode': 200,
        'body': json.dumps('All jobs completed.')
    }
