from pathlib import Path

from pydantic import ValidationError

from .datasource import DataSource, DataSourceError
from .schemas import PhotoRecord, Snapshot


class SyntheticDataSource(DataSource):
    def __init__(self, snapshot_path: Path):
        self.snapshot_path = snapshot_path

    async def snapshot(self) -> Snapshot:
        try:
            return Snapshot.model_validate_json(self.snapshot_path.read_text(encoding="utf-8"))
        except (OSError, ValidationError) as error:
            raise DataSourceError(f"Синтетический набор недоступен или некорректен: {self.snapshot_path}") from error

    async def photo_bytes(self, photo: PhotoRecord) -> bytes:
        if not photo.path:
            raise DataSourceError("У синтетического фото нет пути")
        base = self.snapshot_path.parent.resolve()
        target = (base / photo.path).resolve()
        if not target.is_relative_to(base):
            raise DataSourceError("Путь фото выходит за каталог синтетического набора")
        try:
            return target.read_bytes()
        except OSError as error:
            raise DataSourceError(f"Синтетическое фото недоступно: {photo.path}") from error

