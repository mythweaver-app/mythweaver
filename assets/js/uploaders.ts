// LiveView external uploaders (`MythweaverWeb.Uploads`): `S3` posts each file straight to the
// bucket through the presigned POST form the server prepared, so the bytes never cross the socket.

type UploadEntry = {
  file: File;
  meta: { url: string; fields: Record<string, string> };
  progress(percent: number): void;
  error(reason?: string): void;
  onCancel?(callback: () => void): void;
};

export const Uploaders = {
  S3(entries: UploadEntry[], onViewError: (callback: () => void) => void) {
    entries.forEach((entry) => {
      const form = new FormData();
      Object.entries(entry.meta.fields).forEach(([key, value]) => form.append(key, value));
      // The policy only covers fields before the file, so it goes last.
      form.append("file", entry.file);

      const xhr = new XMLHttpRequest();
      onViewError(() => xhr.abort());
      entry.onCancel?.(() => xhr.abort());

      xhr.onload = () => (xhr.status >= 200 && xhr.status < 300 ? entry.progress(100) : entry.error());
      xhr.onerror = () => entry.error();
      xhr.upload.addEventListener("progress", (event) => {
        if (event.lengthComputable) {
          const percent = Math.round((event.loaded / event.total) * 100);
          if (percent < 100) entry.progress(percent);
        }
      });

      xhr.open("POST", entry.meta.url, true);
      xhr.send(form);
    });
  },
};
