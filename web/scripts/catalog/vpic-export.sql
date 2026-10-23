-- The vPIC database export for the catalog import (0115; docs/seo/coverage-2026-10-23.md): every make, model, model
-- year and vehicle type NHTSA's vPIC knows from its VIN patterns, with the trim names of the VIN schemas that describe
-- one model. Run against the vPIC standalone database (vPICList_lite, public domain, a SQL Server backup published on
-- https://vpic.nhtsa.dot.gov/api/) by the catalog workflow's "vPIC database export" step:
--   sqlcmd -S localhost -U sa -P "$PW" -d vPICList_Lite1 -i scripts/catalog/vpic-export.sql -s $'\t' -W -o export.tsv
-- web/scripts/catalog/import.mjs --vpic-export export.tsv reads it (tab-separated with sqlcmd's header and dashes line,
-- NULL as empty).
SET NOCOUNT ON;
SELECT DISTINCT mk.Name AS make, md.Name AS model, y.yr AS [year], vt.Name AS vehicle_type, CASE WHEN one.VinSchemaId IS NOT NULL THEN st.TrimName END AS [trim]
FROM (
  -- each VIN schema of a WMI over its model years (an open range runs to next year)
  SELECT wvs.WmiId, wvs.VinSchemaId, n.yr
  FROM dbo.Wmi_VinSchema wvs
  CROSS APPLY (SELECT TOP (CASE WHEN COALESCE(wvs.YearTo, YEAR(GETDATE()) + 1) >= wvs.YearFrom THEN COALESCE(wvs.YearTo, YEAR(GETDATE()) + 1) - wvs.YearFrom + 1 ELSE 0 END)
                      wvs.YearFrom + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS yr FROM sys.all_objects) n
) y
JOIN dbo.Wmi w ON w.Id = y.WmiId
JOIN dbo.VehicleType vt ON vt.Id = w.VehicleTypeId
JOIN dbo.Wmi_Make wm ON wm.WmiId = w.Id
JOIN dbo.Make mk ON mk.Id = wm.MakeId
JOIN (SELECT DISTINCT p.VinSchemaId, TRY_CAST(p.AttributeId AS int) AS ModelId
        FROM dbo.Pattern p JOIN dbo.Element e ON e.Id = p.ElementId AND e.Name = 'Model') sm ON sm.VinSchemaId = y.VinSchemaId
JOIN dbo.Model md ON md.Id = sm.ModelId
-- the model belongs to this make (a WMI can serve several makes)
JOIN dbo.Make_Model mm ON mm.MakeId = mk.Id AND mm.ModelId = md.Id
LEFT JOIN (SELECT p.VinSchemaId FROM dbo.Pattern p JOIN dbo.Element e ON e.Id = p.ElementId AND e.Name = 'Model'
            GROUP BY p.VinSchemaId HAVING COUNT(DISTINCT p.AttributeId) = 1) one ON one.VinSchemaId = y.VinSchemaId
LEFT JOIN (SELECT DISTINCT p.VinSchemaId, LTRIM(RTRIM(p.AttributeId)) AS TrimName
             FROM dbo.Pattern p JOIN dbo.Element e ON e.Id = p.ElementId AND e.Name = 'Trim') st ON st.VinSchemaId = y.VinSchemaId
WHERE y.yr BETWEEN 1981 AND YEAR(GETDATE()) + 1;
