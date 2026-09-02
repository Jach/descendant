(in-package #:com.thejach.descendant.binary)

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defun read-file-octets (path)
  "Read PATH entirely into a fresh octet vector."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun read-file-string (path)
  "Read PATH as latin-1 text. The original sources and data files are ISO-8859, not
   UTF-8, so decoding must not assume otherwise."
  (let ((octets (read-file-octets path)))
    (map 'string #'code-char octets)))

(declaim (inline u8-ref u16-ref u32-ref))

(defun u8-ref (octets offset)
  (declare (type octets octets) (type fixnum offset))
  (aref octets offset))

(defun u16-ref (octets offset)
  "Little-endian unsigned 16-bit."
  (declare (type octets octets) (type fixnum offset))
  (logior (aref octets offset)
          (ash (aref octets (1+ offset)) 8)))

(defun u32-ref (octets offset)
  "Little-endian unsigned 32-bit."
  (declare (type octets octets) (type fixnum offset))
  (logior (aref octets offset)
          (ash (aref octets (+ offset 1)) 8)
          (ash (aref octets (+ offset 2)) 16)
          (ash (aref octets (+ offset 3)) 24)))

(defun s32-ref (octets offset)
  "Little-endian signed 32-bit."
  (let ((v (u32-ref octets offset)))
    (if (logbitp 31 v) (- v (ash 1 32)) v)))

(defun asciiz (octets offset max-length)
  "Decode a fixed-width NUL-padded latin-1 string field."
  (let* ((end (or (position 0 octets :start offset :end (+ offset max-length))
                  (+ offset max-length))))
    (map 'string #'code-char (subseq octets offset end))))
