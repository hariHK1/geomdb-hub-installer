[server]
home=/home/pycsw/pycsw
url=${PYCSW_URL}
mimetype=application/xml; charset=UTF-8
encoding=UTF-8
language=id
maxrecords=100
pretty_print=false
domaincounts=true
domainquerytype=range
spatial_ranking=true
profiles=apiso
timeout=30
workers=2

[logging]
level=INFO
logfile=/dev/stdout

[metadata:main]
identification_title=${CSW_TITLE}
identification_abstract=${CSW_ABSTRACT}
identification_keywords=${CSW_KEYWORDS}
identification_keywords_type=theme
identification_fees=${CSW_FEES}
identification_accessconstraints=${CSW_ACCESS_CONSTRAINTS}
provider_name=${CSW_PROVIDER_NAME}
provider_url=${APP_URL}
contact_name=${CSW_CONTACT_NAME}
contact_position=${CSW_CONTACT_POSITION}
contact_address=${CSW_CONTACT_ADDRESS}
contact_city=${CSW_CONTACT_CITY}
contact_stateorprovince=${CSW_CONTACT_PROVINCE}
contact_postalcode=${CSW_CONTACT_POSTALCODE}
contact_country=Indonesia
contact_phone=${CSW_CONTACT_PHONE}
contact_fax=
contact_email=${CSW_CONTACT_EMAIL}
contact_url=${APP_URL}
contact_hours=09:00 - 17:00 WIB
contact_role=pointOfContact

[manager]
transactions=true
allowed_ips=*
uploaddir=/tmp

[repository]
database=postgresql://geomdb:${POSTGRES_PASSWORD}@postgres:5432/geomdb_pycsw
table=records
