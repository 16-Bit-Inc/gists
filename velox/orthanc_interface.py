import requests
import os

class OrthancInterface:
    def __init__(self, report_dir):
        self.DXA_ORTHANC_URL = "http://localhost:8042"
        self.report_ids = []
        self.report_dir = report_dir

        if not os.path.exists(self.report_dir):
            os.makedirs(self.report_dir)

    def _get_report_ids(self):
        data = {
            "Level": "Instance",
            "Query": {
                "SeriesDescription": "Rho-Report"
            }
        }

        headers = {'Content-Type': 'application/json'}
        response = requests.post(f"{self.DXA_ORTHANC_URL}/tools/find", json=data, headers=headers)
        self.report_ids = response.json()
        print(f"Fetched report ids | Num report ids fetched: {len(self.report_ids)}")

    def _download_report_dicoms(self):
        for report_id in self.report_ids:
            print(f"Downloading report with ID: {report_id}")
            response = requests.get(f"{self.DXA_ORTHANC_URL}/instances/{report_id}/file")
            with open(f"{os.path.join(self.report_dir, report_id)}.dcm", "wb") as file:
                file.write(response.content)

    def _delete_reports(self):
        for report_id in self.report_ids:
            response = requests.delete(f"{self.DXA_ORTHANC_URL}/instances/{report_id}")
            if response.status_code == 200:
                print(f"Report ({report_id}) deleted successfully.")
            else:
                print(f"Failed to delete report ({report_id}). Status code: {response.status_code}, Response: {response.text}")

    def process(self):
        self._get_report_ids()
        self._download_report_dicoms()
        self._delete_reports()