#!/bin/sh
set -e

# Substitute ${POSTGRES_PASSWORD} in config template and write to /tmp/pycsw.cfg
python3 - <<'EOF'
import os
tpl = open('/etc/pycsw/pycsw.cfg.tpl').read()
cfg = tpl \
  .replace('${POSTGRES_PASSWORD}',      os.environ.get('POSTGRES_PASSWORD',      'geomdb_secret')) \
  .replace('${APP_URL}',                os.environ.get('APP_URL',                'http://localhost:3000')) \
  .replace('${PYCSW_URL}',              os.environ.get('PYCSW_URL',              'http://localhost:8080/')) \
  .replace('${CSW_TITLE}',              os.environ.get('CSW_TITLE',              'Geomdb Hub CSW')) \
  .replace('${CSW_ABSTRACT}',           os.environ.get('CSW_ABSTRACT',           'OGC Catalogue Service 2.0.2 - Katalog metadata geospasial')) \
  .replace('${CSW_KEYWORDS}',           os.environ.get('CSW_KEYWORDS',           'metadata,geospasial,JIGN,INA-SDI')) \
  .replace('${CSW_FEES}',               os.environ.get('CSW_FEES',               'None')) \
  .replace('${CSW_ACCESS_CONSTRAINTS}', os.environ.get('CSW_ACCESS_CONSTRAINTS', 'None')) \
  .replace('${CSW_PROVIDER_NAME}',      os.environ.get('CSW_PROVIDER_NAME',      'Geomdb Hub')) \
  .replace('${CSW_CONTACT_NAME}',       os.environ.get('CSW_CONTACT_NAME',       'Administrator')) \
  .replace('${CSW_CONTACT_POSITION}',   os.environ.get('CSW_CONTACT_POSITION',   'System Administrator')) \
  .replace('${CSW_CONTACT_ADDRESS}',    os.environ.get('CSW_CONTACT_ADDRESS',    '')) \
  .replace('${CSW_CONTACT_CITY}',       os.environ.get('CSW_CONTACT_CITY',       'Jakarta')) \
  .replace('${CSW_CONTACT_PROVINCE}',   os.environ.get('CSW_CONTACT_PROVINCE',   'DKI Jakarta')) \
  .replace('${CSW_CONTACT_POSTALCODE}', os.environ.get('CSW_CONTACT_POSTALCODE', '')) \
  .replace('${CSW_CONTACT_PHONE}',        os.environ.get('CSW_CONTACT_PHONE',        '')) \
  .replace('${CSW_CONTACT_FAX}',          os.environ.get('CSW_CONTACT_FAX',          '')) \
  .replace('${CSW_CONTACT_EMAIL}',        os.environ.get('CSW_CONTACT_EMAIL',        '')) \
  .replace('${CSW_CONTACT_COUNTRY}',      os.environ.get('CSW_CONTACT_COUNTRY',      'Indonesia')) \
  .replace('${CSW_CONTACT_URL}',          os.environ.get('CSW_CONTACT_URL',          '')) \
  .replace('${CSW_CONTACT_HOURS}',        os.environ.get('CSW_CONTACT_HOURS',        '')) \
  .replace('${CSW_CONTACT_INSTRUCTIONS}', os.environ.get('CSW_CONTACT_INSTRUCTIONS', '')) \
  .replace('${CSW_CONTACT_ROLE}',         os.environ.get('CSW_CONTACT_ROLE',         'pointOfContact'))
open('/tmp/pycsw.cfg', 'w').write(cfg)
print("pycsw config written to /tmp/pycsw.cfg")
EOF

exec python3 /usr/local/bin/entrypoint.py
