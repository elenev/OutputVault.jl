# OutputVault.Formats.ParquetFormat: tables written and read with Parquet2, file metadata included.
module OutputVaultParquet2Ext

using OutputVault.Formats: ParquetFormat
import OutputVault: write_table_file, read_table_file
using Parquet2

write_table_file(::ParquetFormat, path, table, meta) = Parquet2.writefile(path, table; metadata = meta)
read_table_file(::ParquetFormat, path) = Parquet2.Dataset(path)

end # module
