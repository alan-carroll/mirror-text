;; [[file:~/Git/mirror-text/mirror-text.org][implementation using buffer modification hooks]]
;;; mirror-text.el --- Synchronise changes between text regions -*- lexical-binding: t; -*-

;; Version: 0.1
;; Author: Ihor Radchenko <yantar92@gmail.com>
;; Created: 12 April 2020

;;; Commentary:

;; This packages is a framework to create synchronised text regions.
;; The regions may be in the same buffer or in multiple buffers.
;; The text properties can be also synchronised.
;;
;; !!!!! Important
;; This backage is just a proof of concept and will be a subject of breaking changes
;; !!!!!
;;
;; Usage:
;; The main entry point is `mirror-text-create-chunk', which marks the text in current region to be synchronised in future.
;; The marked text is called a chunk.
;; The function returns virtual-chunk, which is the central unit of synchronisation.
;; Regions from virtual-chunk can be inserted to other positions/buffers via `mirror-text--create-chunk' and automatically marked as new chunks.
;; Changes in all the chunks associated with virtual chunk buffer (or regions in this buffer) will be synchronised.
;; 
;; **The following is untested**
;; The virtual chunk buffer may have an active major mode, which will allow uniform fontification of all the chunks.
;; Moreover, the chunks might (not implemented) have overriding keymap, which redirects commands to the virtual chunk buffer.
;; This, in theory, will effectively create separate major mode for all the chunks regardless of the buffer where the chunks are located.
;;
;; Example usage:
;; 1. Activate region of text and run M-x mirror-text-create-chunk
;; This will create mirror-text--virtual-chunks variable containing the created chunk. 
;; 2. To insert a new chunk, evaluate (mirror-text--create-chunk (car mirror-text--virtual-chunks) (point) (1+ (point))) with point where you want to insert the new chunk.
;;

;;; Code:

(defvar mirror-text--virtual-chunks nil
  "List of all the virtual chunk buffers.")

;; TODO: different settings for light&dark backgrounds
(defface mirror-text-background '((t . (:background "Cornsilk")))
  "Face used to indicate the chunks.")

(defface mirror-text-indicator-face '((t . (:background "Red")))
  "Face used to indicate the beginning/end of chunks.")


(defvar mirror-text-beg-chunk-indicator #("#|- " 0 4 (font-lock-face 'mirror-text-indicator-face))
  "String used to indicate the beginning of a chunk.")

(defvar mirror-text-end-chunk-indicator #(" -|#"  0 4 (font-lock-face 'mirror-text-indicator-face))
  "String used to indicate the end of a chunk.")

;; helper functions

(defmacro mirror-text--swap (a b)
  "Swap A and B."
  `(let ((tmp ,a))
     (setf ,a ,b)
     (setf ,b tmp)))

(defun mirror-text--pos-to-marker (pom &optional buffer insertion-type)
  "Convert POM to marker."
  (if (markerp pom)
      pom
    (let ((marker (make-marker)))
      (set-marker marker pom (or buffer (current-buffer)))
      (set-marker-insertion-type marker insertion-type)
      marker)))

(defun mirror-text--markercons= (a b)
  "Return non-nil when cons A = B. Return nil if A or B is nil."
  (and a
       b
       (seq-every-p (lambda (el) (buffer-live-p (marker-buffer el)))
		    (list (car a) (cdr a)
			  (car b) (cdr b)))
       (= (car a) (car b))
       (= (cdr a) (cdr b))))

(defun mirror-text--intersect-cons (c1 c2)
  "Return intersection of two cons regions or nil."
  (when (<= (max (car c1) (car c2))
	    (min (cdr c1) (cdr c2)))
    (cons (max (car c1) (car c2)) (min (cdr c1) (cdr c2)))))

(defun mirror-text--region<= (a b)
  "Return nil when list A > B."
  (or (<= (car a) (car b))
      (<= (cadr a) (cadr b))))

(defun mirror-text--merge-regions (ra rb)
  "Merge RA and RB regions (beg end len chunk)."
  (let* ((a (if (mirror-text--region<= ra rb) ra rb))
	 (b (if (equal a ra) rb ra)))
    (unless (or (> (car b) (cadr a))
		(not (equal (nth 3 a) (nth 3 b)))) ;; not the same chunks
      (list (min (car a) (car b))
	    (max (cadr a) (cadr b))
            (- (max (cadr a) (cadr b))
               (min (car a) (car b)))
            (nth 3 a)))))

(defun mirror-text--add-or-merge-region (region list)
  "Add REGION in the form of (beg end len chunk) to the ordered LIST of regions merging it with existing list elements if possible."
  (let ((elm))
    (setq elm list)
    (while elm
      (let ((cur (car elm))
	    (next (cadr elm)))
	(when (and (mirror-text--region<= cur region)
		   (or (not next)
		       (not (mirror-text--region<= next region))))
	  (let ((merge (mirror-text--merge-regions cur region)))
	    (if merge
		(setcar elm merge)
	      (setcdr elm (cons region (cdr elm)))
	      (setq elm (cdr elm)))
	    (setq cur elm)
	    (setq elm (cdr elm))
	    (while (and elm
			(mirror-text--merge-regions (car cur) (car elm)))
	      (setcar cur (mirror-text--merge-regions (car cur) (car elm)))
	      (setq elm (cdr elm)))
	    (setcdr cur elm)
	    (setq elm nil))))
      (setq elm (cdr elm))
      ))
  (unless list (setq list (list region)))
  list)

;; core chunk code

(defun mirror-text--chunk-modify-function (beg end)
  "Mark the upcoming modifications in the current chunk to be processed by `mirror-text--chunk-after-change-function'."
  (unless (boundp 'mirror-text--buffer-chunk-modifications)
    (make-local-variable 'mirror-text--buffer-chunk-modifications)
    (setq mirror-text--buffer-chunk-modifications nil))
  (let ((inhibit-modification-hooks t))
    ;;(mirror-text--update-chunk beg)
    (add-to-list 'after-change-functions #'mirror-text--chunk-after-change-function)
    (add-to-list 'mirror-text--buffer-chunk-modifications (get-text-property beg 'mirror-text-chunk))))

(defun mirror-text--chunk-after-change-function (beg end oldlen)
  "Propagate the modifications marked by `mirror-text--chunk-modify-function'."
  (require 'org-macs) ;; org-with-point-at
  (when (boundp 'mirror-text--buffer-chunk-modifications)
    (unwind-protect
	(mapc #'mirror-text--update-chunk (mapcar (lambda (chunk) (car (alist-get :region (mirror-text--chunk-info chunk)))) mirror-text--buffer-chunk-modifications))
      (setq mirror-text--buffer-chunk-modifications nil))))

(defun mirror-text--chunk-insert-function (beg end)
  "Handle insertiion into a chunk."
  (mirror-text--update-chunk beg))

;; TODO: consider flagging the synchronized flag in virtual-chunk on modification/insertion
(defun mirror-text--propertize (beg end chunk)
  "Add text properties and modification hooks to the CHUNK text between BEG and END."
  (unless (> end beg) (mirror-text--swap beg end))
  (require 'org-macs) ;; org-with-point-at
  (org-with-point-at beg
    (remove-text-properties beg end '(mirror-text--begoffset nil mirror-text--endoffset nil))
    (put-text-property beg end 'mirror-text-chunk chunk)
    (put-text-property beg end 'front-sticky t) ;; may not be a good idea
    ;; TODO: remove the advice when buffer does not contain any chunks
    
    (put-text-property beg end 'modification-hooks (list #'mirror-text--chunk-modify-function))
    (put-text-property beg end 'insert-in-front-hooks (list #'mirror-text--chunk-insert-function))
    (put-text-property beg end 'insert-behind-hooks (list #'mirror-text--chunk-insert-function))
    ;; (add-function :around (local 'filter-buffer-substring-function) #'mirror-text--buffer-substring-filter)
    (put-text-property beg end  'font-lock-face 'mirror-text-background)
    ;; (put-text-property beg (1+ beg) 'display (concat mirror-text-beg-chunk-indicator (buffer-substring-no-properties beg (1+ beg))))
    ;; (put-text-property (1- end) end 'display (concat (buffer-substring-no-properties (1- end) end) mirror-text-end-chunk-indicator ))
    ))

(defun mirror-text--virtual-chunk-ingest-chunk (chunk-id)
  "Collect the CHUNK-ID contents into the current virtual chunk."
  (when-let* ((chunk (gethash chunk-id mirror-text-chunk-table))
	      (virtual-region (alist-get :virtual-region chunk))
              (region (alist-get :region chunk)))
    (replace-region-contents (car virtual-region)
			     (cdr virtual-region)
                             `(lambda ()
				(let ((beg ,(car region))
                                      (end ,(cdr region)))
				  (org-with-point-at beg
                                    (if (alist-get :keep-text-properties-p chunk)
					(buffer-substring beg end) ;; may consider calling `filter-buffer-substring' here
				      (buffer-substring-no-properties beg end))))))
    (org-with-point-at (car region)
      (let ((inhibit-modification-hooks t)) ; `mirror-text--virtual-chunk-after-change-function' may update the region as well, do not record it
	(org-with-point-at (car virtual-region)
	  (mirror-text--virtual-chunk-after-change-function (car virtual-region) (cdr virtual-region) nil)))))) ;; here it will be possible to selectively copy properties in future

(defun mirror-text--virtual-chunk-after-change-function (beg end oldlen &optional chunk-id chunk)
  "Propagate the insertion from the current virtual chunk into all the linked chunks (or to CHUNK).
Replace the corresponding region in the chunks instead if REPLACE-P is non nil."
  (if (not chunk)
      (progn
	(mirror-text--cleanup (current-buffer))
	(maphash (apply-partially #'mirror-text--virtual-chunk-after-change-function beg end oldlen) mirror-text-chunk-table))
    (when (mirror-text--intersect-cons (cons (mirror-text--pos-to-marker beg) (mirror-text--pos-to-marker end))
				       (alist-get :virtual-region chunk)) 
      (setq beg (car (alist-get :virtual-region chunk)))
      (setq end (cdr (alist-get :virtual-region chunk))) ;; update the whole chunk to avoid messed up pointers
      (let* ((new-text (buffer-substring beg end)) ;; copying with properties, but may need to be more selective in future
	     (real-beg (car (alist-get :region chunk)))
             (real-end (cdr (alist-get :region chunk)))
	     (real-buffer (marker-buffer real-beg)))
	(org-with-point-at real-beg
          (let ((inhibit-read-only t))
            (combine-change-calls  real-beg real-end
				   (replace-region-contents real-beg real-end (lambda () new-text))
				   (mirror-text--propertize real-beg real-end (list (cons ':chunk-id chunk-id)
										    (cons ':virtual-chunk (marker-buffer beg)))))))))))

(defun mirror-text--create-virtual-chunk (text)
  "Create virtual chunk buffer containing TEXT. Return the buffer."
  (let ((buffer (generate-new-buffer (format " mirror-text-virtual-chunk-%s" (sxhash text)))))
    (with-current-buffer buffer
      (insert text)
      (make-local-variable 'mirror-text-chunk-table)
      (setq mirror-text-chunk-table (make-hash-table :test 'equal))
      (add-to-list 'mirror-text--virtual-chunks buffer)
      (setq-local after-change-functions (list #'mirror-text--virtual-chunk-after-change-function)))
    buffer))

(cl-defun mirror-text--create-chunk (virtual-chunk beg end &key
						   (virtual-region (with-current-buffer virtual-chunk
								     (cons (point-min-marker) (point-max-marker))))
                                                   (synchronized-p t)
                                                   (keep-text-properties-p nil))
  "Create a new chunk in VIRTUAL-CHUNK pointing to :region BEG END.
The text in the region will be replaced by the :virtual-region from VIRTUAL-CHUNK."
  (require 'org-id) ;; org-id-uuid
  (setf (car virtual-region) (mirror-text--pos-to-marker (car virtual-region) virtual-chunk))
  (setf (cdr virtual-region) (mirror-text--pos-to-marker (cdr virtual-region) virtual-chunk))
  (setf beg (mirror-text--pos-to-marker beg))
  (setf end (mirror-text--pos-to-marker end))
  ;; (unless (and (markerp beg) (markerp end)) (error "BEG and END should be markers"))
  (set-marker-insertion-type end 'follow-insertion)
  (set-marker-insertion-type (cdr virtual-region) 'follow-insertion)
  (let ((chunk (list (cons ':virtual-region virtual-region)
		     (cons ':region (cons beg end))
		     (cons ':synchronized-p synchronized-p)
                     (cons ':keep-text-properties-p keep-text-properties-p)))
        (chunk-id (org-id-uuid)))
    (unless (member virtual-chunk mirror-text--virtual-chunks) (error "%s is not a virtual chunk buffer" (buffer-name virtual-chunk)))
    (with-current-buffer virtual-chunk
      (puthash chunk-id chunk mirror-text-chunk-table)
      (let ((text (buffer-substring (car virtual-region) (cdr virtual-region))))
	(org-with-point-at beg
          (let ((inhibit-modification-hooks t)
		(inhibit-read-only t))
	    (replace-region-contents beg end (lambda () text))
	    (mirror-text--propertize beg end (list (cons ':chunk-id chunk-id)
						   (cons ':virtual-chunk virtual-chunk)))))))))

;; (defun mirror-text--find-chunk-region (pom)
;;   "Find a chunk region containing POM."
;;   (require 'org-macs) ;; org-with-point-at
;;   (org-with-point-at pom
;;     (let* ((pos (marker-position (mirror-text--pos-to-marker pom)))
;; 	   (beg (and (get-text-property pos 'mirror-text-chunk) pom))
;; 	   (end beg))
;;       (when beg
;; 	(setq beg (or (previous-single-property-change pos 'mirror-text-chunk)
;; 		      beg))
;; 	(setq end (or (next-single-property-change pos 'mirror-text-chunk)
;; 		      end))
;; 	(setq beg (mirror-text--pos-to-marker beg))
;; 	(setq end (mirror-text--pos-to-marker end nil 'move-after-insert))
;; 	(cons beg end)))))

(defun mirror-text--chunk-info (chunk)
  "Return CHUNK info as it is stored in the virtual-chunk buffer.
Return nil when CHUNK is not a valid chunk."
  (let ((virtual-chunk (alist-get :virtual-chunk chunk))
	(chunk-id (alist-get :chunk-id chunk)))
    (if (and chunk-id (buffer-live-p virtual-chunk))
	(with-current-buffer virtual-chunk
          (when (boundp 'mirror-text-chunk-table)
            (gethash chunk-id mirror-text-chunk-table)))
      (mirror-text--cleanup virtual-chunk)
      nil)))

(defun mirror-text--verify-chunk (chunk-info)
  "Return nil when CHUNK-INFO does not point to a valid chunk."
  (require 'org-macs) ;; org-with-point-at
  (let ((region (alist-get :region chunk-info)))
    (when (and (buffer-live-p (marker-buffer (car region)))
	       ;; (mirror-text--markercons= region (mirror-text--find-chunk-region (car region)))
               )
      (with-current-buffer (marker-buffer (car region))
	(equal chunk-info
               (mirror-text--chunk-info (get-text-property (marker-position (car region)) 'mirror-text-chunk)))))))

(defun mirror-text--cleanup (&optional virtual-chunk)
  "Remove orphan VIRTUAL-CHUNK or all the orphan virtual chunks."
  (if (not virtual-chunk)
      (mapc #'mirror-text--cleanup (-select #'identity mirror-text--virtual-chunks))
    (if (not (buffer-live-p virtual-chunk))
	(setq mirror-text--virtual-chunks (delq virtual-chunk mirror-text--virtual-chunks))
      (with-current-buffer virtual-chunk
	(when (boundp 'mirror-text-chunk-table)
	  (mapc (lambda (elm)
		  (unless (cdr elm)
                    (remhash (car elm) mirror-text-chunk-table)))
		(let ((list))
		  (maphash
		   (lambda (key val)
		     (push (cons key
				 (mirror-text--verify-chunk val))
                           list))
		   mirror-text-chunk-table)
                  list))
          (when (hash-table-empty-p mirror-text-chunk-table)
            (setq mirror-text--virtual-chunks (delq virtual-chunk mirror-text--virtual-chunks))
            (kill-buffer virtual-chunk)))))))

(defun mirror-text--update-chunk (&optional pom)
  "Update chunk at POM."
  (require 'org-macs) ; org-with-point-at
  (let* ((pos (or pom (point)))
	 (chunk (get-text-property pos 'mirror-text-chunk))
	 ;; (chunk-region (mirror-text--find-chunk-region pos));;
         (chunk-region (alist-get :region chunk))
         (begoffset (or (get-text-property pos 'mirror-text--begoffset) 0))
         (endoffset (or (get-text-property pos 'mirror-text--endoffset) 0)))
    (when chunk
      (let ((chunk-info (mirror-text--chunk-info chunk)))
	(if (not chunk-info)
            (remove-text-properties (car chunk-region) (cdr chunk-region) '(mirror-text-chunk nil mirror-text--begoffset nil mirror--text-endoffset nil font-lock-face nil))
	  (if (and
                   ;; (mirror-text--markercons= (alist-get :region chunk-info)
		   ;; 			     chunk-region)
                   (zerop begoffset)
                   (zerop endoffset))
              (with-current-buffer (alist-get :virtual-chunk chunk) (mirror-text--virtual-chunk-ingest-chunk (alist-get :chunk-id chunk)))
	    (with-current-buffer (alist-get :virtual-chunk chunk)
	      (let ((virtual-region (alist-get :virtual-region chunk-info)))
		(if (= (- (cdr chunk-region) (car chunk-region))
		       (- (cdr virtual-region) (car virtual-region))) ; same chunk in a new buffer/place
		    (mirror-text--create-chunk (alist-get :virtual-chunk chunk)
					       (car chunk-region)
					       (cdr chunk-region)
					       :virtual-region (cons (car virtual-region)
								     (cdr virtual-region)))
                  (if (= (- (cdr chunk-region) (car chunk-region))
			 (- (- (cdr virtual-region) endoffset) (+ (car virtual-region) begoffset))) ; truncated chunk in a new buffer/place
		      (mirror-text--create-chunk (alist-get :virtual-chunk chunk)
						 (car chunk-region)
						 (cdr chunk-region)
						 :virtual-region (cons (+ (car virtual-region) begoffset)
								       (- (cdr virtual-region) endoffset)))
                    (remove-text-properties (car chunk-region) (cdr chunk-region) '(mirror-text-chunk nil mirror-text--begoffset nil mirror-text--endoffset nil font-lock-face nil))))))))))))

;; This should be used inside advice to the buffer-substring-filter-function
;; Example:
;; (add-function :around (local 'filter-buffer-substring-function)
;;               #'nameless--filter-string)
;; (defun mirror-text--buffer-substring-filter (oldfun beg end &optional delete)
;;   "Detect copied chunks and handle chunks copied partially.
;; The specification follows `filter-buffer-substring-function' requirements."
;;   (when (< end beg) (mirror-text--swap beg end))
;;   (let* ((begchunk-info (mirror-text--chunk-info (get-text-property beg 'mirror-text-chunk)))
;; 	 (endchunk-info (mirror-text--chunk-info (get-text-property (1- end) 'mirror-text-chunk)))
;;          (begoffset (when begchunk-info (- beg (car (alist-get :region begchunk-info)))))
;;          (endoffset (when endchunk-info (- (cdr (alist-get :region endchunk-info)) end)))
;;          (substring (funcall oldfun beg end delete)))
;;     (when substring
;;       (with-temp-buffer
;;         (let ((inhibit-modification-hooks t))
;;           (insert substring)  
;;           ;; (remove-text-properties (point-min) (point-max) '(font-lock-face nil)) ;; may need to be smarter
;; 	  (when begoffset (put-text-property (point-min) (cdr (mirror-text--find-chunk-region (point-min))) 'mirror-text--begoffset begoffset))
;; 	  (when endoffset (put-text-property (car (mirror-text--find-chunk-region (- (point-max) 1))) (point-max) 'mirror-text--endoffset endoffset)))
;; 	(buffer-string)))))

;; TODO: create the minor mode setting modification functions

;; (define-minor-mode mirror-text-mode
;;   "Sync mirror-text fragments in this buffer."
;;   :init-value nil
;;   :lighter " Mirror")

;; exposed to user

(defun mirror-text-create-chunk (beg end &optional buffer)
  "Create a new virtual chunk from region (BEG. END). Mark the region as a chunk."
  (interactive "r")
  (setq beg (mirror-text--pos-to-marker beg buffer))
  (setq end (mirror-text--pos-to-marker end buffer))
  (when (< end beg) (mirror-text--swap beg end))
  (let ((virtual-chunk (mirror-text--create-virtual-chunk (buffer-substring-no-properties beg end))))
    (mirror-text--create-chunk virtual-chunk beg end)))

(provide 'mirror-text)
;; implementation using buffer modification hooks ends here
