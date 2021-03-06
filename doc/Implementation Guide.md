# Implementation Guide

## 1. PostgreSQL configuration

Make sure no statements are ever written to the log files as they contain sensitive card data.

    postgresql.conf:
    log_statement = 'none'

## 2. Purging of cardholder data

To purge expired cardholder data, execute the following SQL command:

    DELETE FROM EncryptedCards WHERE Datestamp < now()-'3 months'::interval;

Replace '3 months' with your customer-defined retention period.

The table EncryptedCards is the only location where encrypted card data is stored.

The deleted encrypted CVC codes might remain on disk for a while after deletion,
due to the design of PostgreSQL. To ensure they are erased, do a VACUUM FULL
ever 10 minutes or so.

## 3. Logging

The logging settings must not be disabled.
If logging would be turned off anyway, doing so will result in non-compliance with PCI DSS.

