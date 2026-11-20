#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys
from unittest import TestCase,main
from unittest.mock import patch
M=Path(__file__).with_name("maya1-dual-backhaul-readonly-audit.py")
spec=importlib.util.spec_from_file_location("maya1_audit",M)
audit=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=audit
spec.loader.exec_module(audit)

class Check(TestCase):
    def test_user_specified_topology(self):
        self.assertEqual(audit.IRAN,"94.184.4.38")
        self.assertEqual(audit.B1,"82.152.132.159")
        self.assertEqual(audit.B2,"152.237.230.77")
        self.assertEqual(audit.DOMAIN,"bh-new.biya2film.top")
        self.assertEqual(len({audit.IRAN,audit.B1,audit.B2}),3)
    def test_no_shell_mutations(self):
        text=M.read_text()
        for forbidden in (
            "systemctl restart","systemctl stop","apt-get install",
            "docker compose up", "os.replace(", "write_text(",
            "ssh root@", "certbot certonly", "iptables -I",
        ):
            self.assertNotIn(forbidden,text)
        self.assertIn('s.sendall(b"show stat\\n")',text)
    def test_dns_requires_only_maya1_a_record(self):
        with patch.object(audit.socket,"getaddrinfo",return_value=[
            (2,1,0,"",("94.184.4.38",0)),
            (2,1,0,"",("94.184.4.38",0))
        ]):
            self.assertEqual(audit.dns(),["94.184.4.38"])
    def test_only_redacted_bundle_fields(self):
        with patch.object(audit.Path,"read_text",return_value=(
            "BH_IRAN_IP='94.184.4.38'\n"
            "BH_FOREIGN_IP='10.0.0.1'\n"
            "BH_TOKEN='SUPER_SECRET_DO_NOT_PRINT'\n"
            "BH_CONTROL_PATH='/secret/path'\n"
        )):
            data=audit.masked_bundle()
        self.assertEqual(data,{"BH_IRAN_IP":"94.184.4.38",
                               "BH_FOREIGN_IP":"10.0.0.1"})
        self.assertNotIn("SUPER_SECRET_DO_NOT_PRINT",str(data))
if __name__=="__main__":
    main(verbosity=2)
