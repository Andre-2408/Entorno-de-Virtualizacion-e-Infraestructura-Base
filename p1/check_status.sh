

echo "Nombre del equipo: "
    hostname
echo ""
    
echo "Direccion IP: "
ip -4 addr show | grep inet | awk '{print $2}' | cut -d/ -f1 | grep -v '127.0.0.1'
echo ""

echo "Espacio en el Disco:"
df -h / | awk 'NR==1 {print "Filesystem      Size  Used Avail Use%"} NR==2 {printf "%-15s %4s  %4s %5s %4s\n", $1, $2, $3, $4, $5}'
echo ""

