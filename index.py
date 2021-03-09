import os
os.environ['AWS_DATA_PATH'] = '/opt/'

from itertools import islice
from datetime import datetime
import time
import json
import boto3

region = os.environ['AWS_REGION']
destination_bucket = os.environ['S3_BUCKET']
inbound_sqs_queue = os.environ['INBOUND_SQS_QUEUE']
outbound_sqs_queue = os.environ['OUTBOUND_SQS_QUEUE']
destination_folder = "adx-cpi/"

# print("Region: {}".format(region))
# print("destination_folder: {}".format(destination_folder))

dataexchange = boto3.client(
    service_name='dataexchange',
    region_name=region
)
s3 = boto3.client(
    service_name='s3',
    region_name=region
)

session = boto3.Session()

sqs = session.client(
    service_name='sqs',
    endpoint_url='https://sqs.us-east-1.amazonaws.com',
)

if not destination_bucket and not inbound_sqs_queue and not outbound_sqs_queue:
    raise Exception("Environment variables. 'S3_BUCKET': {}, 'INBOUND_SQS_QUEUE': {}, 'OUTBOUND_SQS_QUEUE': {}".format(destination_bucket, inbound_sqs_queue, outbound_sqs_queue))

def create_message(dataset_id, revision_id):
    table_name = "world_bank_cpi"
    table_assetlist = {}
    assets_details = dataexchange.list_revision_assets(DataSetId=dataset_id, RevisionId=revision_id)
    assets = assets_details['Assets']
    print('Assets: {}'.format(assets_details))
    for asset in assets:
        asset_name = asset['Name']
        print("Name: {}".format( asset_name))
        if table_name not in table_assetlist:
            table_assetlist[table_name] =[]
        asset_s3_info = {}
        asset_s3_info['bucket'] = destination_bucket
        asset_s3_info['key'] = "adx-cpi/" + dataset_id + "/" + revision_id + "/" + asset_name
        asset_s3_info['version'] = None
        table_assetlist[table_name].append(asset_s3_info)    
    
    message = {}
    message['dataset_id'] = dataset_id
    message['revision_id'] = revision_id
    message['dataFilesMap'] = table_assetlist
    return json.dumps(message)

def handler(event, context):
    print("Boto3 version: {}".format(boto3.__version__))
    print("Event: {}".format(event)) # debug logging
    if 'InitialInit' in event:
        dataset_id = event['InitialInit']['data_set_id']
        revision_ids = [event['InitialInit']['RevisionIds']] 
        print ("Initial revision retrieved. dataset_id: {}, revision_ids: {}".format(dataset_id, revision_id))

    else:    
        for record in event['Records']:
            body = json.loads(record["body"])
            # message = json.loads(body['Message'])
            dataset_id = body['resources'][0]
            revision_ids = body['detail']['RevisionIds']
            print("Event from SQS retrieved. dataset_id: {}, revision_id: {}".format(dataset_id, revision_ids))
            
        # Used to store the Ids of the Jobs exporting the assets to S3.
        job_ids = set()

        # iterate all revision ids to get assets
    for revision_id in revision_ids:
        # Need set retry on a message if lambda fails 3 times to process msg, a cloudwatch event must be raised to notify
                 
        # Start Jobs to export all the assets to S3.
        # try:
            ## Need to add revision asset. dataset
            revision_assets = dataexchange.list_revision_assets(DataSetId=dataset_id, RevisionId=revision_id)
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
                        { 'Bucket': destination_bucket, 'RevisionId': revision_id, 'KeyPattern': destination_folder + dataset_id + "/" + "${Revision.Id}/${Asset.Name}" }
                    ]
                  }
                }    
            )
            # Start the Job and save the JobId.
            dataexchange.start_job(JobId=export_job['Id'])
            job_ids.add(export_job['Id'])

        # except InternalServerException as e:
        #     # Message will be 'in-flight' and will be available for consumption after visibility timeout expires.
        #     print('Error in processing revision: {}'.format(e.message))   #https://docs.aws.amazon.com/data-exchange/latest/apireference/v1-jobs.html
            
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
                sqs.send_message(QueueUrl=outbound_sqs_queue, MessageBody=message, MessageGroupId=dataset_id)
            if get_job_response['State'] == 'ERROR':
                job_errors = get_job_response['Errors']
                raise Exception('JobId: {} failed with errors:\n{}'.format(job_id, job_errors))
            # Sleep to ensure we don't get throttled by the GetJob API.
            time.sleep(0.2)        

    return {
        'statusCode': 200,
        'body': json.dumps('All jobs completed.')
    }