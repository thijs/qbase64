;;;; qbase64.lisp

(in-package #:qbase64)

;;; types and constants

(declaim ((array (unsigned-byte 8)) +empty-bytes+))
(define-constant +empty-bytes+ (make-byte-vector 0))

(declaim (simple-base-string +empty-string+))
(define-constant +empty-string+ (make-string 0 :element-type 'base-char))

(declaim (simple-base-string +original-set+ +uri-set+))

(define-constant +original-set+
    (let ((str "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"))
      (make-array (length str)
                  :element-type 'base-char
                  :initial-contents str)))

(define-constant +uri-set+
    (let ((str "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"))
      (make-array (length str)
                  :element-type 'base-char
                  :initial-contents str)))

(define-constant +pad-char+ #\=)
(declaim (base-char +pad-char+))

(deftype scheme ()
  '(member :original :uri))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (declaim (ftype (function (positive-fixnum t) positive-fixnum) encode-length))
  (defun encode-length (length encode-trailing-bytes)
    (declare (type positive-fixnum length))
    (declare (optimize speed))
    (* 4 (if encode-trailing-bytes
             (ceiling length 3)
             (floor length 3))))

  (declaim (ftype (function (positive-fixnum) positive-fixnum) decode-length))
  (defun decode-length (length)
    (declare (type positive-fixnum length))
    (declare (optimize speed))
    (* 3 (ceiling length 4))))

(define-constant +max-bytes-length+ (- (decode-length most-positive-fixnum) 3)
  "Max length of the byte array that is used as encoding input or decoding output")

(define-constant +max-string-length+ most-positive-fixnum
  "Max length of the string that is used as encoding output or decoding input")


(defun reorder (alphabet salt)
  "Shuffle alphabet by given salt"
  (let ((salt-len (length salt))
        (alphabet (copy-seq alphabet)))
    (when (plusp salt-len)
      (loop :for i :from (1- (length alphabet)) :downto 1
            :for idx := 0 :then (mod (1+ idx) salt-len)
            :for salt-code := (char-code (aref salt idx))
            :for isum := salt-code :then (+ isum salt-code)
            :for j := (mod (+ salt-code idx isum) i)
            :do (rotatef (aref alphabet j) (aref alphabet i))))
    alphabet))


;;; encode

(defun/td %encode (bytes string &key
                         (scheme :original)
                         (salt nil)
                         (encode-trailing-bytes t)
                         (start1 0)
                         (end1 (length bytes))
                         (start2 0)
                         (end2 (length string)))
    (((bytes (simple-array (unsigned-byte 8))) (string simple-base-string))
     ((bytes (simple-array (unsigned-byte 8))) (string simple-string))
     ((bytes (simple-array (unsigned-byte 8))) (string string))
     ((bytes array)                            (string simple-base-string))
     ((bytes array)                            (string simple-string))
     ((bytes array)                            (string string)))
  (declare (type scheme scheme))
  (declare (type positive-fixnum start1 end1 start2 end2))
  (declare (optimize (speed 3) (safety 0) (space 0)))
  (let* ((org-set (ecase scheme
                    (:original +original-set+)
                    (:uri +uri-set+)))
         (set (if salt
                  (reorder org-set salt)
                  org-set)))
    (declare (type simple-base-string set))
    (flet ((encode-byte (byte)
             (char set (logand #o77 byte))))
      (declare (inline encode-byte))
      (loop
         with length1 of-type positive-fixnum = (- end1 start1)
         with length2 of-type positive-fixnum = (- end2 start2)
         with count1 = (multiple-value-bind (count rem)
                           (floor length1 3)
                         (if encode-trailing-bytes
                             (if (plusp rem) (1+ count) count)
                             count))
         with count2 = (floor length2 4)
         for n of-type positive-fixnum below (min count1 count2)
         for i1 of-type positive-fixnum from start1 by 3
         for i2 of-type positive-fixnum from start2 by 4
         for two-missing = (= (- end1 i1) 1)
         for one-missing = (or two-missing (= (- end1 i1) 2))
         for b1 of-type (unsigned-byte 8) = (aref bytes i1)
         for b2 of-type (unsigned-byte 8) = (if two-missing 0 (aref bytes (+ i1 1)))
         for b3 of-type (unsigned-byte 8) =  (if one-missing 0 (aref bytes (+ i1 2)))
         do (setf (char string i2)        (encode-byte (ash b1 -2))
                  (char string (+ i2 1))  (encode-byte
                                           (logior (ash b1 4) (ash b2 -4)))
                  (char string (+ i2 2))  (encode-byte
                                           (logior (ash b2 2) (ash b3 -6)))
                  (char string (+ i2 3)) (encode-byte b3))
         finally
           (when one-missing
             (setf (char string (+ i2 3)) +pad-char+)
             (when two-missing
               (setf (char string (+ i2 2)) +pad-char+)))
           (return (the (values positive-fixnum positive-fixnum)
                        (values (min (+ start1 (* n 3)) end1)
                                (+ start2 (* n 4)))))))))
(defstruct (encoder
             (:constructor %make-encoder))
  "Use an ENCODER to encode bytes to string. Create an encoder using
MAKE-ENCODER, then start encoding bytes using ENCODE."
  (scheme :original :type scheme)
  (pbytes +empty-bytes+ :type (simple-array (unsigned-byte 8)))
  (pbytes-end 0 :type positive-fixnum)
  finish-p)

(defun make-encoder (&key (scheme :original))
  "Creates an ENCODER.

  SCHEME: The base64 encoding scheme to use. Can be :ORIGINAL or :URI"
  (%make-encoder :scheme scheme))

(defun encode (encoder bytes string &key
                                      (salt nil)
                                      (start1 0)
                                      (end1 (length bytes))
                                      (start2 0)
                                      (end2 (length string))
                                      finish)
  "Encodes given BYTES and writes the resultant chars to STRING.

  ENCODER: The encoder

  BYTES: Should be a single-dimentional array of (UNSIGNED-BYTE 8)
  elements.

  STRING: The encoded characters are written into this string.

  START1, END1: Bounds for BYTES

  START2, END2: Bounds for STRING

  FINISH: Padding characters are output if required, and no new bytes
  can be accepted until all the pending bytes are written out.

It is not necessary that all of BYTES are encoded in one go. For
example,

* There may not be enough space left in STRING

* FINISH is not true and the cumulative length of all the bytes given
  till now is not a multiple of 3 (base64 encoding works on groups of
  three bytes).

In these cases, as much as possible BYTES are encoded and the
resultant chars written into STRING, the remaining bytes are copied to
an internal buffer by the encoder and used the next time ENCODE is
called. Also, the second value returned (called PENDINGP, see below)
is set to true.

If FINISH is true but cumulative length of all the BYTES is not a
multiple of 3, padding characters are written into STRING.

ENCODE can be given an empty BYTES array in which case the internal
buffer is encoded as much as possible.

Returns POSITION, PENDINGP.

  POSITION: First index of STRING that wasn't updated

  PENDINGP: True if not all BYTES were encoded"
  (declare (type encoder encoder)
           (type array bytes)
           (type string string)
           (type positive-fixnum start1 end1 start2 end2))
  (assert (<= end1 +max-bytes-length+) ()
          "Length of BYTES should be less than ~A, given ~A"
          +max-bytes-length+ end1)
  (assert (<= end2 +max-string-length+) ()
          "Length of STRING should be less than ~A, given ~A"
          +max-string-length+ end2)
  (bind:bind (((:slots scheme pbytes pbytes-end finish-p) encoder)
              ((:symbol-macrolet len1) (- end1 start1)))
    (when (and (plusp len1) finish-p)
      (error "New BYTES can't be passed when :FINISH was previously true"))

    ;; Check and encode any leftover previous bytes (PBYTES)
    (when (plusp (length pbytes))
      ;; Ensure that PBYTES length is a multiple of 3 by copying from BYTES
      (let* ((last-group-fill-length (rem (- 3 (rem pbytes-end 3)) 3))
             (bytes-to-copy (min len1 last-group-fill-length)))
        (replace pbytes bytes
                 :start1 pbytes-end
                 :end1 (incf pbytes-end bytes-to-copy)
                 :start2 start1
                 :end2 (+ start1 bytes-to-copy))
        (incf start1 bytes-to-copy))
      ;; Then encode PBYTES
      (multiple-value-bind (pos1 pos2)
          (%encode pbytes string
                   :salt salt
                   :scheme scheme
                   :start1 0
                   :end1 pbytes-end
                   :start2 start2
                   :end2 end2
                   :encode-trailing-bytes (and (zerop len1) finish))
        (setf start2 pos2)
        ;; If we can't encode all PBYTES, copy everything from BYTES
        ;; and finish now
        (when (< pos1 pbytes-end)
          (let* ((new-pbytes-length (+ (- pbytes-end pos1) len1))
                 (new-pbytes (make-array (* 3 (ceiling new-pbytes-length 3))
                                         :element-type '(unsigned-byte 8))))
            (replace new-pbytes pbytes
                     :start2 pos1
                     :end2 pbytes-end)
            (replace new-pbytes bytes
                     :start1 (- pbytes-end pos1)
                     :start2 start1
                     :end2 end1)
            (setf pbytes new-pbytes
                  pbytes-end new-pbytes-length
                  finish-p finish)
            (return-from encode (values pos2 t))))))

    ;; Encode BYTES now
    (multiple-value-bind (pos1 pos2)
        (%encode bytes string
                 :salt salt
                 :scheme scheme
                 :start1 start1
                 :end1 end1
                 :start2 start2
                 :end2 end2
                 :encode-trailing-bytes finish)
      ;; If we can't encode all BYTES, copy the remaining to PBYTES
      (when (< pos1 end1)
        (let* ((new-pbytes-length (- end1 pos1))
               (new-pbytes (make-array (* 3 (ceiling new-pbytes-length 3))
                                       :element-type '(unsigned-byte 8))))
          (replace new-pbytes bytes
                   :start2 pos1
                   :end2 end1)
          (setf pbytes new-pbytes
                pbytes-end new-pbytes-length
                finish-p finish)
          (return-from encode (values pos2 t))))

      ;; All bytes encoded
      (setf pbytes +empty-bytes+
            pbytes-end 0
            finish-p nil)
      (return-from encode (values pos2 nil)))))

;;; output stream

(defclass encode-stream (stream-mixin fundamental-binary-output-stream trivial-gray-stream-mixin)
  ((underlying-stream :initarg :underlying-stream)
   encoder
   (string :initform +empty-string+)
   (single-byte-vector :initform (make-byte-vector 1))
   (linebreak :initform 0 :initarg :linebreak)
   (column :initform 0))
  (:documentation
   "A binary output stream that converts bytes to base64 characters
  and writes them to an underlyihng character output stream.

Create an ENCODE-STREAM using MAKE-INSTANCE. The following
initialization keywords are provided:

  UNDERLYING-STREAM: The underlying character output stream to which
  base64 characters are written. Must be given.

  SCHEME: The base64 encoding scheme to use. Must
  be :ORIGINAL (default) or :URI.

  LINEBREAK: If 0 (the default), no linebreaks are written. Otherwise
  its value must be the max number of characters per line.

Note that ENCODE-STREAM does not close the underlying stream when
CLOSE is invoked."))

(defmethod initialize-instance :after ((stream encode-stream) &key (scheme :original))
  (with-slots (encoder)
      stream
    (setf encoder (make-encoder :scheme scheme))))

#-clisp
(defmethod output-stream-p ((stream encode-stream))
  t)

(defmethod stream-element-type ((stream encode-stream))
  '(unsigned-byte 8))

(defun %stream-write-sequence (stream sequence start end finish)
  (when (null end)
    (setf end (length sequence)))
  (bind:bind (((:slots encoder string underlying-stream linebreak column)
               stream)
              ((:slots pbytes-end) encoder)
              (length (encode-length (+ pbytes-end (- end start)) finish)))
    (declare (type encoder encoder))
    (when (< (length string) length)
      (setf string (make-string length :element-type 'base-char)))
    ;; TODO: what happens when STRING size is fixed
    (multiple-value-bind (pos2 pendingp)
        (encode encoder sequence string :start1 start :end1 end :finish finish)
      (declare (ignore pendingp))
      (when (plusp pos2)
        (if (plusp linebreak)
            (loop
               for line-start = 0 then line-end
               for line-end = (min pos2 (+ line-start (- linebreak column)))
               do
                 (write-string string underlying-stream
                               :start line-start
                               :end line-end)
                 (setf column (rem (+ column (- line-end line-start)) linebreak))
                 (when (and (zerop column) (> line-end line-start))
                   (write-char #\Newline underlying-stream))
               while (< line-end pos2))
            (write-string string underlying-stream :end pos2))))
    sequence))

(defmethod stream-write-sequence ((stream encode-stream) sequence start end &key)
  (%stream-write-sequence stream sequence start end nil))

(defmethod stream-write-byte ((stream encode-stream) integer)
  (with-slots (single-byte-vector)
      stream
    (setf (aref single-byte-vector 0) integer)
    (%stream-write-sequence stream single-byte-vector 0 1 nil)
    integer))

(defun flush-pending-bytes (stream)
  (with-slots (linebreak column underlying-stream)
      stream
    (%stream-write-sequence stream +empty-bytes+ 0 0 t)
    (when (and (plusp linebreak) (plusp column))
      (write-char #\Newline underlying-stream)
      (setf column 0))))

(defmethod stream-force-output ((stream encode-stream))
  (flush-pending-bytes stream)
  (force-output (slot-value stream 'underlying-stream)))

(defmethod stream-finish-output ((stream encode-stream))
  (flush-pending-bytes stream)
  (finish-output (slot-value stream 'underlying-stream)))

(defmethod close :before ((stream encode-stream) &key abort)
  (declare (ignore abort))
  (flush-pending-bytes stream))

(defun encode-bytes (bytes &key (scheme :original) (salt nil) (linebreak 0))
  "Encode BYTES to base64 and return the string.

  BYTES: Should be a single-dimentional array of (UNSIGNED-BYTE 8)
  elements.

  SCHEME: The base64 encoding scheme to use. Must
  be :ORIGINAL (default) or :URI.

  SALT: If provided will reorder the alphabet based on SALT.

  LINEBREAK: If 0 (the default), no linebreaks are written. Otherwise
  its value must be the max number of characters per line."
  (if (plusp linebreak)
      ;; If linbreaks are required in the output, use ENCODE-STREAM, else use
      ;; the ENCODER directly
      ;;
      ;; TODO: We should try to add linebreak support in the ENCODER directly,
      ;; this will 1) greatly simplify the gray-streams code, and 2) add an
      ;; important feature directly in the lowest level API
      (with-output-to-string (str nil :element-type 'base-char)
        (with-open-stream (out (make-instance 'encode-stream
                                              :scheme scheme
                                              :underlying-stream str
                                              :linebreak linebreak))
          (write-sequence bytes out)))
      (let ((string (make-string (encode-length (length bytes) t) :element-type 'base-char))
            (encoder (make-encoder :scheme scheme)))
        (multiple-value-bind (pos2 pendingp)
            (encode encoder bytes string :finish t :salt salt)
          (declare (ignore pos2))
          (when pendingp
            (error "Could not encode all bytes to string"))
          string))))

;;; decode

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun reverse-set (set)
    (let ((array (make-array 128
                             :element-type '(unsigned-byte 8)
                             :initial-element 0)))
      (loop
         for i upfrom 0
         for char across set
         do (setf (aref array (char-code char)) i))
      array)))

(define-constant +original-reverse-set+
    (reverse-set +original-set+))

(define-constant +uri-reverse-set+
    (reverse-set +uri-set+))

(declaim (inline whitespace-p))
(defun whitespace-p (c)
  "Returns T for a whitespace character."
  (declare (type character c))
  (declare (optimize speed))
  (or (char= c #\Newline) (char= c #\Space)
      (char= c #\Linefeed) (char= c #\Return)
      (char= c #\Tab)))

(defun/td %decode (string bytes &key
                          (scheme :original)
                          (start1 0)
                          (end1 (length string))
                          (start2 0)
                          (end2 (length bytes)))
    (((string simple-base-string) (bytes (simple-array (unsigned-byte 8))))
     ((string simple-string)      (bytes (simple-array (unsigned-byte 8))))
     ((string string)             (bytes (simple-array (unsigned-byte 8))))
     ((string string)             (bytes (array (unsigned-byte 8))))
     ((string string)             (bytes array)))
  (declare (type scheme scheme)
           (type positive-fixnum start1 end1 start2 end2))
  (declare (optimize (speed 3) (safety 0) (space 0)))
  (let* ((reverse-set (ecase scheme
                        (:original +original-reverse-set+)
                        (:uri +uri-reverse-set+)))
         (i1 start1)
         (i2 start2))
    (declare (type (simple-array (unsigned-byte 8)) reverse-set))
    (declare (type positive-fixnum i1 i2))
    (flet ((next-char ()
             (loop
                for char = (when (< i1 end1) (char string i1))
                do (incf i1)
                while (and char (whitespace-p char))
                finally (return char)))
           (char-to-digit (char)
             (declare (type (or null character) char))
             (if char (aref reverse-set (char-code char)) 0)))
      (declare (inline next-char char-to-digit))
      (the (values positive-fixnum positive-fixnum)
           (loop
              with padded = nil
              for i1-begin of-type positive-fixnum = i1
              for i2-begin of-type positive-fixnum = i2
              for c1 of-type (or null character) = (next-char)
              for c2 of-type (or null character) = (next-char)
              for c3 of-type (or null character) = (next-char)
              for c4 of-type (or null character) = (next-char)
              for d1 of-type (unsigned-byte 8)   = (char-to-digit c1)
              for d2 of-type (unsigned-byte 8)   = (char-to-digit c2)
              for d3 of-type (unsigned-byte 8)   = (char-to-digit c3)
              for d4 of-type (unsigned-byte 8)   = (char-to-digit c4)
              for lb of-type (unsigned-byte 24)  = (logior (ash d1 18)
                                                           (ash d2 12)
                                                           (ash d3 6)
                                                           d4)
              for encode-group = (and c4 (<= (+ i2 3) end2))
              if encode-group
              do (setf (aref bytes i2)       (ash lb -16)
                       (aref bytes (+ i2 1)) (logand #xff (ash lb -8))
                       (aref bytes (+ i2 2)) (logand #xff lb)
                       i2 (+ i2 3)
                       padded (char= +pad-char+ c4))
              while (and encode-group (< i1 end1) (not padded))
              finally
                (return (values (if encode-group i1 i1-begin)
                                (cond ((not encode-group) i2-begin)
                                      ((char= +pad-char+ c3) (+ i2-begin 1))
                                      ((char= +pad-char+ c4) (+ i2-begin 2))
                                      (t i2)))))))))

(defstruct (decoder
             (:constructor %make-decoder))
  "Use a DECODER to decode base64 characters to bytes. Use
MAKE-DECODER to create a decoder, then decode base64 chars using
DECODE."
  scheme
  (pchars (make-string 0 :element-type 'base-char) :type simple-base-string)
  (pchars-end 0))

(defun make-decoder (&key (scheme :original))
  "Creates a DECODER.

  SCHEME: The base64 encoding scheme to use. Can be :ORIGINAL or :URI"
  (%make-decoder :scheme scheme))

(defun resize-pchars (pchars pchars-end new-length)
  (if (< (length pchars) new-length)
      (let ((new-pchars (make-string (least-multiple-upfrom 4 new-length)
                                     :element-type 'base-char)))
        (replace new-pchars pchars :end2 pchars-end))
      pchars))

(defun/td fill-pchars (decoder string &key (start 0) (end (length string)))
    (((string simple-base-string))
     ((string simple-string))
     ((string string)))
  (declare (type decoder decoder)
           (type string string)
           (type positive-fixnum start end))
  (declare (optimize speed))
  (let ((pchars (decoder-pchars decoder))
        (pchars-end (decoder-pchars-end decoder)))
    (declare (type simple-base-string pchars)
             (type positive-fixnum pchars-end))
    (setf pchars (resize-pchars pchars pchars-end (the positive-fixnum
                                                       (+ pchars-end
                                                          (- end start)))))
    (loop
       with i of-type positive-fixnum = pchars-end
       with j of-type positive-fixnum = start
       while (and (< i (length pchars)) (< j end))
       do (let ((char (char string j)))
            (declare (type character char))
            (when (not (whitespace-p char))
              (setf (char pchars i) char)
              (incf i))
            (incf j))
       finally
         (setf (decoder-pchars decoder) pchars
               (decoder-pchars-end decoder) i)
         (return j))))

(defun decode (decoder string bytes &key
                                      (start1 0)
                                      (end1 (length string))
                                      (start2 0)
                                      (end2 (length bytes)))
  "Decodes the given STRING and writes the resultant bytes to BYTES.

  DECODER: The decoder

  STRING: The string to decode.

  BYTES: This is where the resultant bytes are written into. Should be
  a single-dimentional array of (UNSIGNED-BYTE 8) elements.

  START1, END1: Bounds for STRING

  START2, END2: Bounds for BYTES

Whitespace in string is ignored. It is not necessary that the entire
STRING is decoded in one go. For example,

* There may not be enough space left in BYTES,

* or the length of the string (minus whitespace chars) may not be a
  multiple of 4 (base64 decoding works on groups of four characters at
  at time).

In these cases, DECODE will decode as much of the string as it can and
write the resultant bytes into BYTES. The remaining string is copied
to an internal buffer by the decoder and used the next time DECODE is
called. Also, the second return value (called PENDINGP, see below) is
set to true.

DECODE can be given an empty STRING in which case the buffered string
is decoded as much as possible.

Returns POSITION, PENDINGP.

  POSITION: First index of BYTES that wasn't updated

  PENDINGP: True if not all of the STRING was decoded"
  (declare (type decoder decoder)
           (type string string)
           (type array bytes)
           (type positive-fixnum start1 end1 start2 end2))
  (assert (<= end1 +max-string-length+) ()
          "Length of STRING should be less than ~A, given ~A"
          +max-string-length+ end1)
  (assert (<= end2 +max-bytes-length+) ()
          "Length of BYTES should be less than ~A, given ~A"
          +max-bytes-length+ end2)
  (bind:bind (((:slots scheme pchars pchars-end) decoder)
              ((:symbol-macrolet len1) (- end1 start1)))
    (declare (type simple-string pchars))
    (declare (type positive-fixnum pchars-end))

    ;; decode PCHARS first
    (when (plusp pchars-end)
      (setf start1 (fill-pchars decoder string
                                :start start1 :end end1))
      (multiple-value-bind (pos1 pos2)
          (%decode pchars bytes
                   :scheme scheme
                   :start1 0 :end1 pchars-end
                   :start2 start2 :end2 end2)
        (when (< pos1 pchars-end)
          ;; no more decoding can be done at this point, shift
          ;; remaining PCHARS left, slurp STRING and return
          (replace pchars pchars :start2 pos1 :end2 pchars-end)
          (decf pchars-end pos1)
          (fill-pchars decoder string :start start1 :end end1)
          (return-from decode (values pos2 t)))
        (setf pchars-end 0 start2 pos2)))

    ;; Decode STRING now
    (multiple-value-bind (pos1 pos2)
        (%decode string bytes
                 :scheme scheme
                 :start1 start1
                 :end1 end1
                 :start2 start2
                 :end2 end2)
      (when (< pos1 end1)
        (fill-pchars decoder string :start pos1 :end end1))
      (values pos2 (plusp pchars-end)))))

;;; input stream

(defclass decode-stream (stream-mixin fundamental-binary-input-stream trivial-gray-stream-mixin)
  ((underlying-stream :initarg :underlying-stream)
   decoder
   (string :initform +empty-string+)
   (buffer :initform (make-byte-vector 3))
   (buffer-end :initform 0)
   (single-byte-vector :initform (make-byte-vector 1)))
  (:documentation
   "A binary input stream that converts base64 chars from an
   underlying stream to bytes.

Create a DECODE-STREAM using MAKE-INSTANCE. The following
initialization keywords are provided:

  UNDERLYING-STREAM: The underlying character input stream from which
  base64 chars are read. Must be given.

  SCHEME: The base64 encoding scheme to use. Must
  be :ORIGINAL (default) or :URI.

Note that DECODE-STREAM does not close the underlying stream when
CLOSE is invoked."))

(defmethod initialize-instance :after ((stream decode-stream) &key (scheme :original))
  (with-slots (underlying-stream decoder)
      stream
    (setf decoder (make-decoder :scheme scheme))))

#-clisp
(defmethod input-stream-p ((stream decode-stream))
  t)

(defmethod stream-element-type ((stream decode-stream))
  '(unsigned-byte 8))

(defun write-buffer-to-sequence (stream sequence start end)
  (let ((buffer (slot-value stream 'buffer))
        (buffer-end (slot-value stream 'buffer-end)))
    (if (plusp buffer-end)
        (let ((bytes-copied (min (- end start) buffer-end)))
          (replace sequence buffer
                   :start1 start :end1 end
                   :start2 0 :end2 buffer-end)
          (replace buffer buffer
                   :start2 bytes-copied :end2 buffer-end)
          (decf (slot-value stream 'buffer-end) bytes-copied)
          (+ start bytes-copied))
        start)))

(defmethod stream-read-sequence ((stream decode-stream) sequence start end &key)
  (when (null end)
    (setf end (length sequence)))
  (bind:bind (((:slots decoder string underlying-stream buffer buffer-end) stream)
              ((:slots pchars-end) decoder)
              ((:symbol-macrolet length) (- end start)))
    (loop
       with eof = nil
       while (and (< start end) (not eof))
       do
         (setf start (write-buffer-to-sequence stream sequence start end))
       when (< start end)
       do
         (let ((string-end (encode-length length t)))
           (when (< (length string) string-end)
             (setf string (make-string string-end)))
           (bind:bind ((end1 (read-sequence string underlying-stream :end string-end))
                       ((:values pos2 pendingp)
                        (decode decoder string sequence
                                :end1 end1
                                :start2 start
                                :end2 end)))
             (setf eof (and (zerop end1) (< end1 string-end)))
             (when (and (< pos2 end) pendingp)
               (setf buffer-end (decode decoder +empty-string+ buffer
                                        :start2 buffer-end))
               (setf pos2 (write-buffer-to-sequence stream sequence pos2 end)))
             (setf start pos2)))
       finally (return start))))

(defmethod stream-read-byte ((stream decode-stream))
  (with-slots (single-byte-vector)
      stream
    (let ((pos (stream-read-sequence stream single-byte-vector 0 1)))
      (if (zerop pos)
          :eof
          (aref single-byte-vector 0)))))

(defun decode-string (string &key (scheme :original))
  "Decodes base64 chars in STRING and returns an array
of (UNSIGNED-BYTE 8) elements.

  STRING: The string to decode.

  SCHEME: The base64 encoding scheme to use. Must
  be :ORIGINAL (default) or :URI."
  (let ((bytes (make-byte-vector (decode-length (length string))))
        (decoder (make-decoder :scheme scheme)))
    (multiple-value-bind (pos2 pendingp)
        (decode decoder string bytes)
      (when pendingp
        (error "Input base64 string was not complete"))
      (if (= pos2 (length bytes))
          bytes
          (make-array pos2
                      :element-type '(unsigned-byte 8)
                      :displaced-to bytes)))))
