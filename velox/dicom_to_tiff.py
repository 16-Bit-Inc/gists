import pydicom
from PIL import Image
from datetime import datetime
import calendar

class Dicom2Tiff:
    def __init__(self, dicom_path: str, tiff_path: str):
        self.dicom_path = dicom_path
        self.tiff_path = tiff_path
        self.dicom_image = pydicom.dcmread(self.dicom_path)
        self.tags_map = {
            65280: "PatientName",
            65282: "PatientID",
            65283: "StudyDate",
            65284: "StudyTime",
            65287: "StudyID",
            65312: "PatientSex",
            65319: "UniqueDeviceIdentifier",  # Rho version
            65321: "AccessionNumber",
            65322: "StudyDate",
            65323: "AcquisitionTime",
            65325: "RhoScore",
            65327: "StudyInstanceUID",
            65347: "SeriesInstanceUID",
            65348: "SOPInstanceUID",
            65375: "SeriesNumber",
            65376: "InstanceNumber",  # always 1
            65377: "AcquisitionDate",
            65378: "AcquisitionTime",
            65392: "StudyDescription",
            65393: "SeriesDescription",
        }

    def _convert_gregorian_to_julian_date(self, gregorian_date_str: str):
        # Define the Gregorian date to convert
        gregorian_date = datetime.strptime(gregorian_date_str, "%Y%m%d")

        # Convert Gregorian date to tuple
        time_tuple = gregorian_date.timetuple()

        # Convert to seconds since epoch
        seconds_since_epoch = calendar.timegm(time_tuple)

        # Convert seconds since epoch to Julian Day Number
        jdn_from_epoch = 2440587.5 + (seconds_since_epoch / (24 * 60 * 60))

        return round(jdn_from_epoch)

    def _convert_dicom_to_tiff(self):

        # Convert DICOM image data to a format that Pillow can handle (e.g., a NumPy array)
        image_data = self.dicom_image.pixel_array

        # Create a PIL image from the array
        image = Image.fromarray(image_data)

        # Save the image as TIFF with the custom tag
        image.save(self.tiff_path, format="TIFF")

    def _add_tags_to_tiff(self):
        image = Image.open(self.tiff_path)

        # To set photometric interpretation as RGB
        image.tag[65286] = "Report" 

        for tiff_tag, dicom_tag in self.tags_map.items():

            if dicom_tag.endswith("Date"):
                image.tag[tiff_tag] = str(
                    self._convert_gregorian_to_julian_date(
                        self.dicom_image[dicom_tag].value
                    )
                )
            elif dicom_tag.endswith("Time"):
                image.tag[tiff_tag] = str(
                    datetime.strptime(
                        self.dicom_image[dicom_tag].value, "%H%M%S.%f"
                    ).strftime("%H:%M:%S")
                )
            elif dicom_tag == "InstanceNumber":
                image.tag[tiff_tag] = "1"
            elif dicom_tag == "RhoScore":
                image.tag[tiff_tag] = str(self.dicom_image[0x2001, 0x0020].value)
            else:
                image.tag[tiff_tag] = str(self.dicom_image[dicom_tag].value)

        image.save(self.tiff_path, tiffinfo=image.tag)

    def convert(self):
        self._convert_dicom_to_tiff()
        self._add_tags_to_tiff()

    def get_metadata(self):
        img = Image.open(self.tiff_path)
        metadata = img.tag_v2
        metadata = dict(sorted(metadata.items()))
        print(metadata)