import os
os.environ['AWS_DATA_PATH'] = '/opt/'

from itertools import islice
import boto3
from datetime import datetime
import time
import json

region = os.environ['AWS_REGION']
destination_bucket = os.environ['S3_BUCKET']
topic_arn='arn:aws:sns:us-east-1:304289345267:adx-s3export-new-revision-event-topic'

def create_message(dataset_id, revision_id):
    message = {
        'dataset_id' : dataset_id,
        'revision_id': revision_id
    }
    return json.dumps(message)

# Grouper recipe from standard docs: https://docs.python.org/3/library/itertools.html
def grouper(iterable, n):
    iterator = iter(iterable)
    group = tuple(islice(iterator, n))
    while group:
        yield group
        group = tuple(islice(iterator, n))

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
    sns = boto3.client(
        service_name='sns',
        region_name=region
    )
    # message = sqs.receive_message(
    #     QueueUrl='https://sqs.us-east-1.amazonaws.com/635065826439/adx_sqs_queue'
    # )
    print("Boto3 version: {}".format(boto3.__version__))
    for record in event['Records']: ## check if 'for' of 'if' shall be used
        body = json.loads(record["body"])
        message = json.loads(body['Message'])
        print('Message: {}'.format(message))
        dataset_id = message['resources'][0]
        revision_ids = message['detail']['RevisionIds']
        print("DatasetID: {}".format(dataset_id))
        print('Revisions: {}'.format(revision_ids))

    # Used to store the Ids of the Jobs exporting the assets to S3.
    job_ids = set()

    # iterate all revision ids to get assets
    for revision_id in revision_ids:
        # Start Jobs to export all the assets to S3.
        # We export in batches of 100 as the StartJob API has a limit of 10000.
        revision_assets = dataexchange.list_revision_assets(DataSetId=dataset_id, RevisionId=revision_id)
        assets_chunks = grouper(revision_assets['Assets'], 10000)
        for assets_chunk in assets_chunks:
            # Create the Job which exports assets to S3.
            export_job = dataexchange.create_job(
                Type='EXPORT_REVISIONS_TO_S3',
                Details={
                    'ExportRevisionsToS3': {
                        'DataSetId': dataset_id,
            # 'Encryption': {
            #     'KmsKeyArn': 'string',
            #     'Type': 'aws:kms'|'AES256'
            # },
                        'RevisionDestinations': [
                            { 'Bucket': destination_bucket, 'RevisionId': revision_id }
                        ]
                    }
                }    
            )
            # Start the Job and save the JobId.
            dataexchange.start_job(JobId=export_job['Id'])
            job_ids.add(export_job['Id'])

    # Iterate until all remaining workflow have reached a terminal state, or an error is found.
    completed_jobs = set()
    while job_ids != completed_jobs:
        for job_id in job_ids:
            if job_id in completed_jobs:
                continue
            get_job_response = dataexchange.get_job(JobId=job_id)
            if get_job_response['State'] == 'COMPLETED':
                print ("Job {} completed".format(job_id))
                completed_jobs.add(job_id)
                # publish event in SNS Topic
                message = create_message(dataset_id,revision_ids[0])
                sns.publish(TopicArn=topic_arn, Message=message, Subject='ADX New Revision Event')
            if get_job_response['State'] == 'ERROR':
                job_errors = get_job_response['Errors']
                raise Exception('JobId: {} failed with errors:\n{}'.format(job_id, job_errors))
            # Sleep to ensure we don't get throttled by the GetJob API.
            time.sleep(0.2)        

    return {
        'statusCode': 200,
        'body': json.dumps('All jobs completed.')
    }

