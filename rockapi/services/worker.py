import django
import os

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'rockproject.settings')
django.setup()

from rockapi.services.sqs_service import SqsService

SqsService().start()