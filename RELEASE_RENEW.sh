echo "RELEASE "
sudo nmcli connection down test-dhcp
ip a show ens37 | grep "inet "
echo ""

echo "RENEW"
sudo nmcli connection up test-dhcp
ip a show ens37 | grep "inet "
echo ""

echo "Datos recibidos"
echo "Gateway:"
ip route | grep ens37 | grep default
echo "DNS:"
cat /etc/resolv.conf | grep nameserver