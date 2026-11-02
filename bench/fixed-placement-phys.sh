# usage: fixed-placement-phys.sh <file>  - prints the extent count and an md5 of the physical extent list
f=${1:?usage: $0 <file>}
filefrag -v "$f" | sed -n '/^ *[0-9]*:/p' | tr -d '.:' | awk '{print $4, $5}' | sort -n | awk 'NR==1{s=$1;e=$2;next} $1==e+1{e=$2;next} {print s"-"e; s=$1;e=$2} END{print s"-"e}' > /tmp/phys.now
wc -l < /tmp/phys.now; md5sum < /tmp/phys.now
