

;; Must not impletment socket in threadS
;; It will become 3 times slower.

;; (require 'thread-packet)

(defvar threadS-stop nil
  "Thread will stop if it is set to t.")

(defconst threadS-stream "threadS-stream"
  "Process name of the data stream.
Implement through localhost.")

(defconst threadS-sender "threadS-sender"
  "Process name of the data stream sender.")

(defvar threadS-id nil
  "Name of this thread.")

(defvar threadS-port nil
  "Port of the thread server")

(defvar threadS-parent-port nil
  "Port of thre parent thread.")

(defvar threadS-buffer '(0)
  ;; Minimum need to have a list for nconc 
  "Buffer for imcomplete received data.")

(defsign threadS-quit-signal
  "A block signal to be emitted when it receives
a quit message from parent thread.")

(defconst threadS-child-thread-quene-folder
  (file-name-as-directory (concat (file-name-as-directory user-emacs-directory) "thread"))
  ;; This is shit!!
  )


(defun threadS-init ()

  "Ininialize and listen to main process for instruction."
  
  ;; Get parent port
  (let ((info (read-from-minibuffer "" nil nil t)))
    (setq threadS-id (car info)
          threadS-parent-port (cdr info)))

  
  ;; Start stream for listening data
  ;; in terms of network process
  ;; Should be the faster way to get data from another process
  (make-network-process :name threadS-stream
                        :server t
                        :host 'local
                        :service t
                        :family 'ipv4
                        :filter 'threadS-receive-data
                        :nowait t)

  ;; Store the local server port that need to send back to parent
  (setq threadS-port (process-contact (get-process threadS-stream) :service))

  ;;! This sleep time is very important
  ;;! In parent thread, it is doing
  ;; ;; Register the thread to the thread--record
  ;; (setf (cdr (assoc thread-num thread--record)) thread)
  ;; threadS-send-system-data need to do after parent thread has finished this operation
  (sleep-for 0.1)
  (threadS-send-port-data threadS-port)

  ;; Redirect 'message to parent's log
  (advice-add 'message :around 'threadS-message)
  
  (while (null threadS-stop)
    (sleep-for 0.5)))





(defun threadS-receive-data (proc data)

  "Process received data."
  ;; It needs to be very efficient.
  ;; As it fails to do so, parent process will be blocking
  ;; just for waiting it for process receiving data.

  ;; Data will arrived as string.
  ;; Large data will be split into small data chunks at parent process.
  ;; A newline charater "\n" indicates the end of the chunks.
  ;; One chunk is sent at a time.
  ;; Depends on OS, the max. data size for a data chunk is fixed, say 4kb for my PC.
  ;; So data chunk is put in thread-buffer first.
  ;; And combine to form a complete data when the newline character is met.

  ;;; Debug only
  ;; (prin1 data)

  
  ;; Check only the last character
  (if (string-match "\n" data (- (length data) 1))
      (progn
        (nconc threadS-buffer (list data))
        (threadS-process-data)
        (setq threadS-buffer (list 0))) ;; Need to use (list 0) instead of '(0)
    ;; nconc is 100 times faster than concat a string
    (nconc threadS-buffer (list data))))





(defun threadS-process-data ()

  "Process a complete data from thread-buffer."
  ;; It won't block the parent process.
  ;; Efficiency is not care. XD
  
  ;; Combine the list
  (let ((string (mapconcat 'identity (cdr threadS-buffer) ""))
        packet
        packet-type)
    ;; Cut the last newline char
    (setq string (substring string 0 (- (length string) 1)))
    (setq packet (read string))
    
    (when (thread.packet-p packet)
      (setq packet-type (thread.packet.getType packet))
      (cond
       ((eq packet-type 'exe)
        (threadS-exe-packet-handler packet))
       ((eq packet-type 'code)
        (threadS-code-packet-handler packet))
       ((eq packet-type 'quit)
        (threadS-quit))))))
  
  






(defun threadS-send-data (packet)

  "When `thread-socket--outbound-signal' is emitted in the socket,
this function is invoked to really send out data through the network stream."

  ;; (let ((sender (open-network-stream threadS-sender
  ;;                                    nil
  ;;                                    "localhost"
  ;;                                    threadS-parent-port
  ;;                                    'plain)))
  (let ((data (concat (prin1-to-string packet) "\n"))
        sender
        filename
        files)

    (if (> (length data) 50000)
        (progn
          (setq filename (number-to-string (time-to-seconds (current-time))))
          (write-region "" nil (concat threadS-child-thread-quene-folder filename))

          (setq files (directory-files threadS-child-thread-quene-folder nil "[[:digit:]]+.*"))

          (while (null (string= (car files) filename))
            (accept-process-output nil nil 0.1)
            (setq files (directory-files threadS-child-thread-quene-folder nil "[[:digit:]]+.*"))))

      (when (setq files (directory-files threadS-child-thread-quene-folder nil "[[:digit:]]+.*"))
        (setq filename (number-to-string (time-to-seconds (current-time))))
        (write-region "" nil (concat threadS-child-thread-quene-folder filename))

        (while (null (string= (car files) filename))
            (accept-process-output nil nil 0.1)
            (setq files (directory-files threadS-child-thread-quene-folder nil "[[:digit:]]+.*")))))
       
    (while (null (setq sender (ignore-errors
                                (open-network-stream threadS-sender
                                                     nil
                                                     "localhost"
                                                     threadS-parent-port
                                                     'plain))))
      (accept-process-output nil nil 0.1))
    
    (process-send-string sender data)
    ;; sender must be deleted
    ;; Otherwise, an odd process will be appeared in parent thread. 
    (delete-process sender)

    (when filename
        (delete-file (concat threadS-child-thread-quene-folder filename)))))

;; (defun threadS-send-data-sentinel (process event)

;;   (threadS-debug-write-file "time" (format-time-string "%Y%m%d - %l:%M:%S%p") "process" process "event" event)
;;   )


(defun threadS-send-port-data (data)

  "Send port number back to parent thread."

  (threadS-send-data
   (make-instance 'thread.packet
                  :source threadS-id
                  :type 'port
                  :data data)))


(defun threadS-send-err-data (&optional error-code error-handler data)

  "Send reply back to parent thread."
  
  (threadS-send-data
   (make-instance 'thread.packet
                  :source threadS-id
                  :type 'err
                  :error-handler error-handler
                  :data (and error-handler (cons error-code data)))))


(defun threadS-send-msg-data (data)

  "Send message back to parent thread."

  (threadS-send-data
   (make-instance 'thread.packet
                  :source threadS-id
                  :type 'msg
                  :data data)))


(defun threadS-send-quit ()

  "Send signal to parent thread that it is safe to quit."
  
  (threadS-send-data
   (make-instance 'thread.packet
                  :source threadS-id
                  :type 'quit
                  :data t)))


(defun threadS-send-rpy-data (&optional reply-func data)

  "Send reply back to parent thread."
  
  (threadS-send-data
   (make-instance 'thread.packet
                  :source threadS-id
                  :type 'rpy
                  :reply reply-func
                  :data (and reply-func (list data)))))


(defun threadS-send-tgi-data (function data)

  "Send instruction generated by child thread."
  
  (threadS-send-data
   (make-instance 'thread.packet
                  :source threadS-id
                  :type 'tgi
                  :reply function
                  :data data)))









(defun threadS-quit ()
  "Terminate the thread."
  (emitB threadS-quit-signal)
  (threadS-send-quit))


(defun threadS-exe-packet-handler (packet)

  "Execute the instruction issued from the parent thread.
It replies with the returning result of the execution to the parent thread.
Otherwise, it will reply nil.
If there is any error during the execution of instrustion,
a packet will be sent to notify the error."

  (let ((data (thread.packet.getData packet))
        (reply-func (thread.packet.getReply packet))
        (error-handler (thread.packet.getErrorHandler packet))
        error-info
        result)

        (setq result (condition-case list
                     (apply (car data) (cdr data))
                   (error list
                          (setq error-info list))))
        
    (if error-info
        (threadS-send-err-data (car data) error-handler error-info)
      (threadS-send-rpy-data reply-func result))))



(defun threadS-code-packet-handler (packet)

  "Evaluate the code issued from the parent thread.
It replies with the returning result of the evaluation to the parent thread.
Otherwise, it will reply nil.
If there is any error during the evaluation of code,
a packet will be sent to notify the error."
  
  (let ((code (thread.packet.getData packet))
        (reply-func (thread.packet.getReply packet))
        (error-handler (thread.packet.getErrorHandler packet))
        error-info
        result)
        
    (setq result (condition-case list
                     (eval code)
                   (error list
                          (setq error-info list))))
    
    (if error-info
        (threadS-send-err-data code error-handler error-info)
      (threadS-send-rpy-data reply-func result))))







(defun threadS-message (orig-func &rest args)

  "Message is meaningless in child thread.
  So send it back to parent."

  (let ((message (ignore-errors (apply 'format args))))
    (when message
      (threadS-send-msg-data message))))




  




(defun threadS-setq (var value)
  "setq for thread."
  (setq var value))

(defun threadS-set-load-path (path)
  (setq load-path path))

(defun threadS-require-packet (&rest packets)
  (dolist (packet (car packets))
    (require packet)))






(defun threadS-do-nothing (orig-func &rest args)
  ;; Advice this funcion around 'message to prevent flooding of stdout
  "Seriously, this is a function doing nothing.
If you can read this documentation, either you are
reading the source code or you are doing something
that is nothing."
  nil)


(defun threadS-debug-write-file (&rest datas)

  (let (string)
    (dolist (data datas)
      (if (stringp data)
          (setq string (concat string data "\n"))
        (setq string (concat string (prin1-to-string data) "\n"))))
    (write-region string
                  nil
                  (format "/home/tom/.emacs.d/elpa/thread/test/%d" threadS-id)
                  t)))





;; Testing

(defun my-stupid-rehash (input)

  (secure-hash 'sha512 input))

(defun my-stupid-rehash-helper (input count)
  
  (while (> count 0)
    (setq input (my-stupid-rehash input))
    (setq count (1- count)))
  (message input))

;;   (defun echo-server-stop nil
;;     "stop an emacs echo server"
;;     (interactive)
;;     (while  echo-server-clients
;;       (delete-process (car (car echo-server-clients)))
;;       (setq echo-server-clients (cdr echo-server-clients)))
;;     (delete-process "echo-server")
;;     )

;; ;; Local Variables:
;; ;; byte-compile-warnings:`' (not free-vars unresolved)
;; ;; `'End:

(provide 'thread-server)
