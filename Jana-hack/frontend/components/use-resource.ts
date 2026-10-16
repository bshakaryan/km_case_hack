"use client";

import { useCallback, useEffect, useState } from "react";
import { ApiClient, errorMessage } from "@/lib/api";

export function useResource<T>(api: ApiClient, path: string) {
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<{ data: T | null; loading: boolean; error: string | null }>({ data: null, loading: true, error: null });
  const reload = useCallback(() => setRevision((value) => value + 1), []);
  useEffect(() => {
    let active = true;
    setState((old) => ({ ...old, loading: true, error: null }));
    api.call<T>(path).then((data) => { if (active) setState({ data, loading: false, error: null }); })
      .catch((error: unknown) => { if (active) setState((old) => ({ ...old, loading: false, error: errorMessage(error) })); });
    return () => { active = false; };
  }, [api, path, revision]);
  return { ...state, reload };
}
export type Resource<T> = ReturnType<typeof useResource<T>>;
