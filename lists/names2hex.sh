while read line; do
	name_hex=$(echo -n $line | xxd -p)
	name_hex_lower=$(echo -n $line | tr [:upper:] [:lower:] | xxd -p)
	name_hex_upper=$(echo -n $line | tr [:lower:] [:upper:] | xxd -p)
echo $name_hex
echo $name_hex_lower
echo $name_hex_upper
done < names.txt

