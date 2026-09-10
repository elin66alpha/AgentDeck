'use strict';

const express = require('express');

module.exports = function createFsRouter(ctx) {
  const {
    MAX_DOWNLOAD_BYTES,
    MAX_UPLOAD_BYTES,
    eventWorkdir,
    fs,
    listAbsoluteDirectory,
    path,
    prepareDownload,
    prepareDownloadAbsolute,
    queryBool,
    recentWorkdirs,
    requestWorkdir,
    resolveAbsoluteUploadTarget,
    resolveUploadTarget,
    sendDirectoryZip,
    sendFilesystemError,
    sendWorkdirError,
    streamUploadToFile,
    uploadedEntry,
    validateWorkdir,
    workdirBusy,
  } = ctx;
  const router = express.Router();

  router.get('/api/workdir', (req, res) => {
    try {
      const dir = requestWorkdir(req);
      return res.json({ dir, busy: workdirBusy(dir) });
    } catch (err) {
      return sendWorkdirError(res, err);
    }
  });

  router.get('/api/workdirs/recent', (_req, res) => {
    res.json({ workdirs: recentWorkdirs() });
  });

  // Validate (and optionally create) a path the device wants to switch to. With
  // per-device workdirs there is no global state to change here: the client
  // stores the returned canonical path locally and sends it back via x-workdir.
  router.post('/api/workdir', (req, res) => {
    try {
      const result = validateWorkdir(req.body && req.body.path, {
        create: req.body && req.body.create === true,
      });
      return res.json({
        ok: true,
        dir: result.dir,
        created: result.created,
      });
    } catch (err) {
      return sendWorkdirError(res, err);
    }
  });

  router.get('/api/workdir/browse', async (req, res) => {
    try {
      return res.json(
        await listAbsoluteDirectory(req.query.path, {
          showHidden: queryBool(req.query.showHidden),
          fallbackDir: eventWorkdir(req),
        }),
      );
    } catch (err) {
      return sendFilesystemError(res, err);
    }
  });

  router.get('/api/fs/download', async (req, res) => {
    let download;
    try {
      // The unified file browser sends absolute paths (it can reach anywhere up to
      // root); older relative paths stay confined to the workdir. Both enforce the
      // size cap so an oversized transfer is refused before it starts.
      if (req.query.path && path.isAbsolute(String(req.query.path))) {
        download = await prepareDownloadAbsolute(req.query.path, {
          maxBytes: MAX_DOWNLOAD_BYTES,
        });
      } else {
        download = await prepareDownload(req.query.path, requestWorkdir(req), {
          maxBytes: MAX_DOWNLOAD_BYTES,
        });
      }
    } catch (err) {
      return sendFilesystemError(res, err);
    }

    if (!download.isDirectory) {
      return res.download(download.target, download.filename, (err) => {
        if (err && !res.headersSent) {
          return sendFilesystemError(res, err);
        }
        return undefined;
      });
    }

    return sendDirectoryZip(download, res);
  });

  router.post('/api/fs/upload', async (req, res) => {
    // Refuse oversized transfers before reading any body bytes when the client
    // declares a length; undeclared (chunked) bodies are cut off mid-stream.
    const declared = parseInt(req.get('content-length') || '', 10);
    if (Number.isFinite(declared) && declared > MAX_UPLOAD_BYTES) {
      return res.status(413).json({
        error: 'upload exceeds the size limit',
        code: 'FS_UPLOAD_TOO_LARGE',
      });
    }
    let target;
    try {
      // Absolute target from the unified browser, or workdir-relative (legacy).
      if (req.query.path && path.isAbsolute(String(req.query.path))) {
        target = resolveAbsoluteUploadTarget(req.query.path, req.query.name);
      } else {
        target = resolveUploadTarget(req.query.path, req.query.name, requestWorkdir(req));
      }
      if (fs.existsSync(target.target)) {
        const realTarget = fs.realpathSync(target.target);
        if (
          realTarget !== target.realRoot &&
          !realTarget.startsWith(`${target.realRoot}${path.sep}`)
        ) {
          return res.status(403).json({
            error: 'path is outside the work directory',
            code: 'FS_PATH_OUTSIDE_WORKDIR',
          });
        }
      }
      await streamUploadToFile(req, target.target, MAX_UPLOAD_BYTES);
      return res.json({
        ok: true,
        entry: uploadedEntry(target.root, target.target),
      });
    } catch (err) {
      return sendFilesystemError(res, err);
    }
  });

  return router;
};
