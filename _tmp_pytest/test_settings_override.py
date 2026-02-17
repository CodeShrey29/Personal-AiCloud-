# Override to use SQLite for local testing on Windows
import os
import sys

# Set paths before importing seahub settings
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'seahub.settings')

# Import everything from seahub.settings
from seahub.settings import *

# Override DB to SQLite for local testing
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': os.path.join(os.path.dirname(__file__), 'test.db'),
    }
}
