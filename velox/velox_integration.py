import os
import time
import warnings
from orthanc_interface import OrthancInterface
from dicom_to_tiff import Dicom2Tiff
import shutil

warnings.filterwarnings("ignore")

RHO_REPORTS_DIR = "rho_reports"
FAILED_RHO_REPORTS_DIR = "failed_rho_reports"
TIFF_REPORTS_DIR = r"C:\Program Files (x86)\Lunar\DICOM\Reports"
QUERY_INTERVAL = 10

while True:
    # catch orthanc interface exceptions
    try:
        OrthancInterface(report_dir=RHO_REPORTS_DIR).process()
        for dicom_filename in os.listdir(RHO_REPORTS_DIR):
            # catch exceptions while processing the dicoms
            try:
                print(f"Processing dicom file: {dicom_filename}")
                dicom_path = os.path.join(RHO_REPORTS_DIR, dicom_filename)
                tiff_dir_path = os.path.join(
                    TIFF_REPORTS_DIR, dicom_filename.split(".")[0]
                )
                if not os.path.exists(tiff_dir_path):
                    os.makedirs(tiff_dir_path)
                tiff_path = os.path.join(tiff_dir_path, "report.tiff")
                Dicom2Tiff(
                    dicom_path=dicom_path,
                    tiff_path=tiff_path,
                ).convert()
                os.remove(dicom_path)
            except Exception as e:
                if not os.path.exists(FAILED_RHO_REPORTS_DIR):
                    os.makedirs(FAILED_RHO_REPORTS_DIR)
                print(
                    f"Exception while processing dicom: {e} | Moving the dicom file: {dicom_filename} to {FAILED_RHO_REPORTS_DIR}."
                )
                shutil.move(
                    dicom_path, os.path.join(FAILED_RHO_REPORTS_DIR, dicom_filename)
                )
                # remove the empty folders in the TIFF directory
                shutil.rmtree(tiff_dir_path)
        time.sleep(QUERY_INTERVAL)
    except Exception as e:
        print(f"Exception: {e}")
        time.sleep(QUERY_INTERVAL)
