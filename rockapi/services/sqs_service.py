import json
import boto3
import os
from django.conf import settings
from rockapi.models import RockImage


class SqsService:
    def __init__(self):
        self.sqs = boto3.client('sqs', region_name=settings.AWS_REGION)
        self.queue_url = os.environ['SQS_QUEUE_URL']

    def start(self):
        print('Worker started, polling SQS...')
        while True:
            response = self.sqs.receive_message(
                QueueUrl=self.queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20
            )
            for message in response.get('Messages', []):
                self._process(message)

    def _process(self, message):
        body = json.loads(message['Body'])
        bucket = body['bucket']
        original_key = body['original_key']
        thumbnail_keys = body['thumbnail_keys']

        original_url = f"https://{bucket}.s3.amazonaws.com/{original_key}"

        try:
            image = RockImage.objects.get(original_url=original_url)
            image.thumbnail_small_url  = f"https://{bucket}.s3.amazonaws.com/{thumbnail_keys['small']}"
            image.thumbnail_medium_url = f"https://{bucket}.s3.amazonaws.com/{thumbnail_keys['medium']}"
            image.thumbnail_large_url  = f"https://{bucket}.s3.amazonaws.com/{thumbnail_keys['large']}"
            image.status = 'ready'
            image.save()
            print(f'Updated image {image.id} to ready')
        except RockImage.DoesNotExist:
            print(f'No RockImage found for {original_url}')

        self.sqs.delete_message(
            QueueUrl=self.queue_url,
            ReceiptHandle=message['ReceiptHandle']
        )