from abc import ABC, abstractmethod

from .schemas import PhotoRecord, Snapshot


class DataSourceError(RuntimeError):
    pass


class IncompleteHistory(DataSourceError):
    pass


class DataSource(ABC):
    @abstractmethod
    async def snapshot(self) -> Snapshot:
        raise NotImplementedError

    @abstractmethod
    async def photo_bytes(self, photo: PhotoRecord) -> bytes:
        raise NotImplementedError
