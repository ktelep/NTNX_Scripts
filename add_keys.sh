#!/bin/bash

# Quick script to take a directory of public key files named "Key_name.pub"
# and add them as public keys for authentication on a Prism Element cluster
# This is useful when rotating a number of keys, note it does not REMOVE 
# any keys from the configuration
#
#   ncli cluster ls-public-keys -- Show you currently install keys
#   ncli cluster rm-public-key  -- Remove a public key
#   ncli cluster add-public-key -- Add a public key$a
#
# Keys can be any compatible type and length
# A datecode is added to each name given
# 
# Ex.
#   Filename - Kurt_Telep.pub
#   Current Date - June 3, 2024
#   Key Name Generated - Kurt_Telep_20240603
#

# Set to the directory where your public keys currently reside on the CVM
KEY_PATH=/tmp/keys

DATECODE=`date +%Y%m%d`

for i in $(ls $KEY_PATH/*.pub)
do
	# Extract the name from the filename itself
	filename=$(basename -- "$i")
	filename="${filename%.*}"

        # Generate our Key Name
	KEYNAME="${filename}_${DATECODE}"

        # Add the key, note if a key already exists, we will continue
	echo "Adding Key ${KEYNAME}"
	ncli cluster add-public-key name=${KEYNAME} file-path=${i}
done

