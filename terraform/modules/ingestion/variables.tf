variable "name_prefix" {
  description = "Prefix for naming resources"
  type        = string
}

variable "lake_bucket_name" {
  description = "Data lake bucket the job writes raw files to and reads its script from"
  type        = string
}

variable "raw_database_name" {
  description = "Glue database the job registers bronze tables in"
  type        = string
}

variable "drive_folder_id" {
  description = "ID of the Google Drive folder to copy CSV files from"
  type        = string
}
